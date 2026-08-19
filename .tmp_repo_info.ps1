$ErrorActionPreference = 'Stop'
$credOutput = "url=https://github.com`n" | git credential fill 2>$null
$ghToken = ($credOutput | Where-Object { $_ -match '^password=' }) -replace '^password=', ''
$headers = @{ Authorization = "Bearer $ghToken"; Accept = "application/vnd.github+json" }

function Get-Json($uri) { Invoke-RestMethod -Uri $uri -Headers $headers }

# 1. ohos 仓库信息
$repo = Get-Json "https://api.github.com/repos/AzadKuu/venera-ohos"
Write-Output "=== AzadKuu/venera-ohos ==="
Write-Output "default_branch = $($repo.default_branch)"
Write-Output "fork = $($repo.fork)"
if ($repo.fork) {
  Write-Output "parent = $($repo.parent.full_name) (default=$($repo.parent.default_branch))"
  Write-Output "source = $($repo.source.full_name) (default=$($repo.source.default_branch))"
}
Write-Output "pushed_at = $($repo.pushed_at)"

# 2. ohos 仓库分支列表
Write-Output "`n=== branches in AzadKuu/venera-ohos ==="
$branches = Get-Json "https://api.github.com/repos/AzadKuu/venera-ohos/branches?per_page=50"
$branches | ForEach-Object { Write-Output "  $($_.name) -> $($_.commit.sha.Substring(0,7)) (protected=$($_.protected))" }

# 3. 本地远程与分支跟踪
Write-Output "`n=== local remotes ==="
git -C D:\workspace\venera remote -v
Write-Output "`n=== local branches (-vv) ==="
git -C D:\workspace\venera branch -vv
