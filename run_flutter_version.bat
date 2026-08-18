@echo off
set PATH=C:\Windows\System32;C:\Windows;C:\Windows\System32\Wbem;C:\Windows\System32\WindowsPowerShell\v1.0;C:\Program Files\Git\bin;C:\Program Files\Git\cmd
D:\workspace\flutter\ohos-flutter\bin\flutter.bat --version 2>&1
echo === Supported platforms ===
D:\workspace\flutter\ohos-flutter\bin\flutter.bat create --help 2>&1
