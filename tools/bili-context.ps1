# bili-context.ps1 -- B站 video context: metadata, subtitles, danmaku digest.
# Sits in video-watch/scripts so both the watchdog and any other caller share one source.
# ASCII only on purpose: PowerShell 5.1 misreads non-BOM UTF-8.
#
# Usage:
#   . "C:\Users\sakur\.dsh\skills\video-watch\scripts\bili-context.ps1"
#   $ctx = Get-BiliContext -Runner { param($a) Invoke-BskTab $sid $tab $a } -Aid 123 -Bvid BVxxx -Title "..."

function Get-BiliContext {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Runner,
        [string]$Aid = "",
        [string]$Bvid = "",
        [string]$Title = "",
        [int]$HotLimit = 8,
        [int]$MaxDigestChars = 600
    )

    $result = [pscustomobject]@{
        ok             = $false
        aid            = $Aid
        cid            = ""
        desc           = ""
        danmaku_count  = 0
        danmaku_digest = ""
        subtitle       = ""
        note           = ""
    }

    # ---- 1) view api: cid / desc / danmaku count
    $q = if ($Aid) { "aid=$Aid" } elseif ($Bvid) { "bvid=$Bvid" } else { "" }
    if (-not $q) { $result.note = "no aid/bvid"; return $result }

    $js1 = "fetch('https://api.bilibili.com/x/web-interface/view?$q',{credentials:'include'}).then(r=>r.json()).then(j=>{if(!j.data)return 'ERR';return JSON.stringify({aid:j.data.aid,cid:j.data.cid,desc:(j.data.desc||''),dm:(j.data.stat&&j.data.stat.danmaku)||0});})"
    $out1 = ""
    for ($i = 1; $i -le 2; $i++) {
        $out1 = & $Runner @("evaluate", $js1)
        if ($out1 -match '"cid"') { break }
        Start-Sleep -Seconds 2
    }
    $m1 = [regex]::Match($out1, '\{.*\}', 'Singleline')
    if (-not $m1.Success) { $result.note = "view api failed"; return $result }
    try { $meta = $m1.Value | ConvertFrom-Json } catch { $result.note = "view api parse failed"; return $result }

    $result.ok = $true
    $result.aid = [string]$meta.aid
    $result.cid = [string]$meta.cid
    $d = [string]$meta.desc
    $d = ($d -replace "`r?`n", " / ").Trim()
    if ($d.Length -gt 300) { $d = $d.Substring(0, 300) + "..." }
    $result.desc = $d
    $result.danmaku_count = [int]$meta.dm

    # ---- 2) subtitle (official / AI captions uploaded with the video)
    $aid2 = $result.aid
    $cid2 = $result.cid
    $js2 = "fetch('https://api.bilibili.com/x/player/v2?aid=$aid2&cid=$cid2',{credentials:'include'}).then(r=>r.json()).then(k=>{var s=(((k.data||{}).subtitle||{}).subtitles||[]);if(!s.length)return '[]';var u=s[0].subtitle_url;if(u.indexOf('//')===0)u='https:'+u;return fetch(u,{credentials:'include'}).then(r=>r.json()).then(t=>JSON.stringify((t.body||[]).map(function(x){return [x.from,x.content];})));})"
    $out2 = ""
    for ($i = 1; $i -le 2; $i++) {
        $out2 = & $Runner @("evaluate", $js2)
        if ($out2 -match '\[\[') { break }
        Start-Sleep -Seconds 2
    }
    $m2 = [regex]::Match($out2, '\[\[.*\]\]', 'Singleline')
    if ($m2.Success) {
        try {
            $arr = @($m2.Value | ConvertFrom-Json)
            $sb = New-Object System.Text.StringBuilder
            foreach ($row in $arr) {
                $t = [double]$row[0]
                $mm = [int][Math]::Floor($t / 60)
                $ss = [int][Math]::Floor($t - $mm * 60)
                [void]$sb.AppendLine(("[{0:00}:{1:00}] {2}" -f $mm, $ss, ([string]$row[1]).Trim()))
            }
            $result.subtitle = $sb.ToString().Trim()
        } catch { }
    }

    # ---- 3) danmaku digest: per-minute density + a few lines around the hottest minutes
    if ($result.danmaku_count -gt 0) {
        $js3 = "fetch('https://api.bilibili.com/x/v1/dm/list.so?oid=$cid2',{credentials:'include'}).then(r=>r.text()).then(t=>{var doc=new DOMParser().parseFromString(t,'text/xml');var ds=[].slice.call(doc.querySelectorAll('d'));if(!ds.length)return '{}';var b={},arr=[];ds.forEach(function(d){var p=parseFloat(d.getAttribute('p').split(',')[0]);arr.push([p,d.textContent]);var k=Math.floor(p/60);b[k]=(b[k]||0)+1;});var pm=Object.keys(b).map(function(k){return [parseInt(k,10),b[k]];}).sort(function(a,b){return a[0]-b[0];});var peaks=pm.slice().sort(function(a,b){return b[1]-a[1];}).slice(0,3).map(function(x){return x[0];});var hot=[];arr.forEach(function(x){var p=x[0];if(hot.length<20&&peaks.some(function(m){return p>=m*60&&p<(m+1)*60;})){hot.push([Math.round(p),x[1]]);}});return JSON.stringify({total:ds.length,pm:pm,peaks:peaks,hot:hot});})"
        $out3 = ""
        for ($i = 1; $i -le 2; $i++) {
            $out3 = & $Runner @("evaluate", $js3)
            if ($out3 -match '"total"') { break }
            Start-Sleep -Seconds 2
        }
        $m3 = [regex]::Match($out3, '\{.*\}', 'Singleline')
        if ($m3.Success) {
            try {
                $dm = $m3.Value | ConvertFrom-Json
                $parts = @()
                $dens = @()
                foreach ($row in @($dm.pm)) {
                    $mm = [int]$row[0]
                    $dens += ("{0}分:{1}" -f $mm, $row[1])
                }
                if ($dens.Count -gt 0) { $parts += ("弹幕密度（按分钟）：" + ($dens -join "，")) }
                $hotLines = @()
                foreach ($h in @($dm.hot)) {
                    $sec = [int]$h[0]
                    $hh = [int][Math]::Floor($sec / 60)
                    $ss = $sec - $hh * 60
                    $hotLines += ("[{0:00}:{1:00}] {2}" -f $hh, $ss, ([string]$h[1]).Trim())
                    if ($hotLines.Count -ge $HotLimit) { break }
                }
                if ($hotLines.Count -gt 0) { $parts += ("高能处弹幕：" + ($hotLines -join " / ")) }
                $digest = ($parts -join "`n").Trim()
                if ($digest.Length -gt $MaxDigestChars) { $digest = $digest.Substring(0, $MaxDigestChars) + "..." }
                $result.danmaku_digest = $digest
            } catch { }
        }
    }

    return $result
}
