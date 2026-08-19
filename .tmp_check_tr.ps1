$json = Get-Content D:\workspace\venera\assets\translation.json -Raw | ConvertFrom-Json
Write-Output "top-level keys: $($json.PSObject.Properties.Name -join ', ')"
Write-Output "zh_CN key count: $($json.zh_CN.PSObject.Properties.Count)"
Write-Output "=== check existing keys ==="
$keys = @('App','Data','User','Language','Initial Page','AI super resolution','Enhance manga images with on-device AI')
foreach ($k in $keys) {
  $line = "  '$k': "
  foreach ($lang in $json.PSObject.Properties.Name) {
    $v = $json.$lang
    if ($v.PSObject.Properties.Name -contains $k) {
      $line += "$lang='$($v.$k)' "
    }
  }
  Write-Output $line
}
