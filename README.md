# prank

PowerShell-скрипт, который:

- скачивает картинки из `images` этого репозитория;
- складывает их в локальный кэш;
- показывает их в плавающих окнах;
- переключает обои рабочего стола по кругу.

Быстрый запуск из PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/Jumarf123/prank/main/prank.ps1')))"
```

Быстрый запуск из `cmd.exe`:

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/Jumarf123/prank/main/prank.ps1')))"
```

Только скачать картинки в кэш без запуска:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/Jumarf123/prank/main/prank.ps1'))) -DownloadOnly"
```
