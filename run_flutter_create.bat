@echo off
set PATH=C:\Windows\System32;C:\Windows;C:\Windows\System32\Wbem;C:\Windows\System32\WindowsPowerShell\v1.0;C:\Program Files\Git\bin;C:\Program Files\Git\cmd
set PUB_HOSTED_URL=https://pub.flutter-io.cn
set FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
cd /d D:\workspace\venera
echo === Creating OHOS Platform ===
D:\workspace\flutter\ohos-flutter\bin\flutter.bat create --platforms=ohos .
echo === Exit code: %ERRORLEVEL% ===
