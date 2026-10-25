# YamlLite.ps1 - minimal YAML reader for occt-builder configuration files.
#
# Windows PowerShell 5.1 has no built-in YAML support and we do not want to
# require extra modules, so this parser supports the subset of YAML used by
# occt-build.yaml:
#   - nested maps by indentation (spaces only)
#   - block lists ("- item") of scalars
#   - inline lists ([a, b, c]) and empty maps ({})
#   - scalars: plain, 'single' or "double" quoted, true/false/yes/no/on/off,
#     integers, null/~
#   - full-line and trailing comments (#)
# Anchors, multi-line strings and flow maps are not supported.

function Remove-YamlComment([string]$Line) {
    $inSingle = $false
    $inDouble = $false
    for ($i = 0; $i -lt $Line.Length; $i++) {
        $c = $Line[$i]
        if ($c -eq "'" -and -not $inDouble) { $inSingle = -not $inSingle }
        elseif ($c -eq '"' -and -not $inSingle) { $inDouble = -not $inDouble }
        elseif ($c -eq '#' -and -not $inSingle -and -not $inDouble) {
            if ($i -eq 0 -or $Line[$i - 1] -match '\s') { return $Line.Substring(0, $i) }
        }
    }
    return $Line
}

function ConvertFrom-YamlScalar([string]$Text) {
    $t = $Text.Trim()
    if ($t.Length -ge 2 -and $t.StartsWith('"') -and $t.EndsWith('"')) {
        return $t.Substring(1, $t.Length - 2).Replace('\"', '"').Replace('\\', '\')
    }
    if ($t.Length -ge 2 -and $t.StartsWith("'") -and $t.EndsWith("'")) {
        return $t.Substring(1, $t.Length - 2).Replace("''", "'")
    }
    if ($t -eq '' -or $t -eq '~' -or $t -eq 'null') { return $null }
    if ($t -eq '{}') { return [ordered]@{} }
    if ($t.StartsWith('[') -and $t.EndsWith(']')) {
        $inner = $t.Substring(1, $t.Length - 2).Trim()
        $items = @()
        if ($inner -ne '') {
            foreach ($part in $inner.Split(',')) { $items += , (ConvertFrom-YamlScalar $part) }
        }
        return , $items
    }
    switch -regex ($t) {
        '^(?i)(true|yes|on)$' { return $true }
        '^(?i)(false|no|off)$' { return $false }
        '^-?\d+$' { return [long]$t }
    }
    return $t
}

function Read-YamlBlock($Lines, [ref]$Index, [int]$Indent) {
    $first = $Lines[$Index.Value]
    if ($first.Text.StartsWith('- ') -or $first.Text -eq '-') {
        $list = @()
        while ($Index.Value -lt $Lines.Count) {
            $l = $Lines[$Index.Value]
            if ($l.Indent -lt $Indent) { break }
            if ($l.Indent -gt $Indent) { throw "YAML line $($l.Number): unexpected indentation" }
            # end of a list written at the same indentation as its parent key
            if (-not ($l.Text.StartsWith('- ') -or $l.Text -eq '-')) { break }
            $list += , (ConvertFrom-YamlScalar $l.Text.Substring(1))
            $Index.Value++
        }
        return , $list
    }

    $map = [ordered]@{}
    while ($Index.Value -lt $Lines.Count) {
        $l = $Lines[$Index.Value]
        if ($l.Indent -lt $Indent) { break }
        if ($l.Indent -gt $Indent) { throw "YAML line $($l.Number): unexpected indentation" }
        $m = [regex]::Match($l.Text, '^("[^"]*"|''[^'']*''|[^:]+?)\s*:(\s+(.*))?$')
        if (-not $m.Success) { throw "YAML line $($l.Number): expected 'key: value', got '$($l.Text)'" }
        $key = ConvertFrom-YamlScalar $m.Groups[1].Value
        $rest = $m.Groups[3].Value
        $Index.Value++
        if ($rest.Trim() -ne '') {
            $map[[string]$key] = ConvertFrom-YamlScalar $rest
        }
        elseif ($Index.Value -lt $Lines.Count -and $Lines[$Index.Value].Indent -gt $Indent) {
            $map[[string]$key] = Read-YamlBlock $Lines $Index $Lines[$Index.Value].Indent
        }
        elseif ($Index.Value -lt $Lines.Count -and $Lines[$Index.Value].Indent -eq $Indent -and $Lines[$Index.Value].Text.StartsWith('- ')) {
            # "key:" followed by a list at the same indentation (valid YAML)
            $map[[string]$key] = Read-YamlBlock $Lines $Index $Indent
        }
        else {
            $map[[string]$key] = $null
        }
    }
    return $map
}

function ConvertFrom-YamlLite([string]$Text) {
    $lines = New-Object System.Collections.ArrayList
    $number = 0
    foreach ($raw in ($Text -split "`r?`n")) {
        $number++
        if ($raw -match "`t") { throw "YAML line ${number}: tabs are not allowed, use spaces" }
        $clean = (Remove-YamlComment $raw).TrimEnd()
        if ($clean.Trim() -eq '' -or $clean.Trim() -eq '---') { continue }
        $indent = $clean.Length - $clean.TrimStart().Length
        [void]$lines.Add([pscustomobject]@{ Indent = $indent; Text = $clean.Trim(); Number = $number })
    }
    if ($lines.Count -eq 0) { return [ordered]@{} }
    $index = 0
    $result = Read-YamlBlock $lines ([ref]$index) $lines[0].Indent
    if ($index -lt $lines.Count) { throw "YAML line $($lines[$index].Number): unexpected indentation" }
    return $result
}

function Read-YamlFile([string]$Path) {
    return ConvertFrom-YamlLite ([System.IO.File]::ReadAllText($Path))
}
