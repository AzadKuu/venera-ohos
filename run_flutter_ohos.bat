@echo off
set PATH=C:\Windows\System32;C:\Windows;C:\Windows\System32\Wbem;C:\Windows\System32\WindowsPowerShell\v1.0;C:\Program Files\Git\bin;C:\Program Files\Git\cmd
cd /d D:\workspace\venera
echo === Flutter Version ===
D:\workspace\flutter\ohos-flutter\bin\flutter.bat --version 2>&1
echo === Creating OHOS Platform ===
D:\workspace\flutter\ohos-flutter\bin\ohos-flutter\bin\flutter.bat create --platforms=ohos . 2>&1
echo === Done (exit: %ERRORLEVEL%) ===
