#!/usr/bin/env python3
"""Patch the freshly generated Flutter android/ folder:
- Google services Gradle plugin
- minSdk 23
- location / internet permissions + queries for geo: and https:
"""
import re
from pathlib import Path

root = Path("android")

# 1) settings.gradle(.kts): declare google-services plugin
for name in ("settings.gradle.kts", "settings.gradle"):
    f = root / name
    if f.exists():
        s = f.read_text()
        if "com.google.gms.google-services" not in s:
            if name.endswith(".kts"):
                add = '    id("com.google.gms.google-services") version "4.4.2" apply false\n'
                pat = r'(\s*id\("com\.android\.application"\)[^\n]*\n)'
            else:
                add = '    id "com.google.gms.google-services" version "4.4.2" apply false\n'
                pat = r'(\s*id\s*"com\.android\.application"[^\n]*\n)'
            s, n = re.subn(pat, lambda m: m.group(1) + add, s, count=1)
            assert n == 1, f"could not patch {name}"
            f.write_text(s)

# 2) app/build.gradle(.kts): apply plugin + minSdk
for name in ("build.gradle.kts", "build.gradle"):
    f = root / "app" / name
    if f.exists():
        s = f.read_text()
        if "com.google.gms.google-services" not in s:
            if name.endswith(".kts"):
                add = '    id("com.google.gms.google-services")\n'
                pat = r'(\s*id\("com\.android\.application"\)[^\n]*\n)'
            else:
                add = '    id "com.google.gms.google-services"\n'
                pat = r'(\s*id\s*"com\.android\.application"[^\n]*\n)'
            s, n = re.subn(pat, lambda m: m.group(1) + add, s, count=1)
            assert n == 1, f"could not patch {name}"
        s = re.sub(r'minSdk(?:Version)?\s*=?\s*flutter\.minSdkVersion',
                   'minSdk = 23', s)
        f.write_text(s)

# 3) AndroidManifest.xml
m = root / "app/src/main/AndroidManifest.xml"
s = m.read_text()
if "ACCESS_FINE_LOCATION" not in s:
    block = """    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION"/>
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
    <queries>
        <intent><action android:name="android.intent.action.VIEW"/><data android:scheme="geo"/></intent>
        <intent><action android:name="android.intent.action.VIEW"/><data android:scheme="https"/></intent>
    </queries>
"""
    s, n = re.subn(r'(\s*)<application', lambda mm: "\n" + block + mm.group(1) + "<application", s, count=1)
    assert n == 1, "could not patch manifest"
    m.write_text(s)

print("android/ patched OK")
