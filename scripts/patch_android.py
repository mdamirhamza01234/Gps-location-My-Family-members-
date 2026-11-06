#!/usr/bin/env python3
"""Patch the freshly generated Flutter android/ folder:
- Google services Gradle plugin
- minSdk 23
- location / background / notification / SMS permissions, geo: + https: queries
- background location service (foregroundServiceType=location) + notification icon
Every step is idempotent.
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

perms = [
    "INTERNET",
    "ACCESS_FINE_LOCATION",
    "ACCESS_COARSE_LOCATION",
    "ACCESS_BACKGROUND_LOCATION",
    "FOREGROUND_SERVICE",
    "FOREGROUND_SERVICE_LOCATION",
    "POST_NOTIFICATIONS",
    "WAKE_LOCK",
    "RECEIVE_BOOT_COMPLETED",
    "REQUEST_IGNORE_BATTERY_OPTIMIZATIONS",
    "SEND_SMS",
    "ACCESS_NETWORK_STATE",
]
block = ""
for p in perms:
    if f"android.permission.{p}" not in s:
        block += f'    <uses-permission android:name="android.permission.{p}"/>\n'
if 'android.hardware.telephony' not in s:
    block += '    <uses-feature android:name="android.hardware.telephony" android:required="false"/>\n'
if "<queries>" not in s:
    block += """    <queries>
        <intent><action android:name="android.intent.action.VIEW"/><data android:scheme="geo"/></intent>
        <intent><action android:name="android.intent.action.VIEW"/><data android:scheme="https"/></intent>
    </queries>
"""
if block:
    s, n = re.subn(r'(\s*)<application', lambda mm: "\n" + block + mm.group(1) + "<application", s, count=1)
    assert n == 1, "could not add permissions to manifest"

# App ka display naam (launcher icon ke niche, aur recents me).
s, n = re.subn(r'android:label="[^"]*"', 'android:label="Family GPS Tracker"', s, count=1)
assert n == 1, "could not set app label"

if "flutter_background_service.BackgroundService" not in s:
    svc = """
        <service
            android:name="id.flutter.flutter_background_service.BackgroundService"
            android:foregroundServiceType="location"
            android:exported="true"/>
"""
    s, n = re.subn(r'(<application[^>]*>)', lambda mm: mm.group(1) + svc, s, count=1)
    assert n == 1, "could not add service to manifest"
m.write_text(s)

# 3b) root android/build.gradle.kts: some plugins (another_telephony) still ship
# Kotlin jvmTarget 1.8 while the app compiles Java 11 -> force both to 11.
root_build = root / "build.gradle.kts"
if root_build.exists():
    s = root_build.read_text()
    marker = "// jvmTarget alignment for plugins"
    if marker not in s:
        # Only the another_telephony plugin ships Kotlin jvmTarget 1.8 while its
        # own Java task compiles at 11 -> match Kotlin to that module's own
        # Java target. Scoped to this one module so every other module (which
        # already matches on its own, e.g. at 17) is left untouched.
        s += f"""
{marker}
project(":another_telephony") {{
    tasks.withType(JavaCompile::class.java).configureEach {{
        sourceCompatibility = "11"
        targetCompatibility = "11"
    }}
    tasks.withType(org.jetbrains.kotlin.gradle.tasks.KotlinCompile::class.java).configureEach {{
        compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11)
    }}
}}
"""
        root_build.write_text(s)

# 4) Notification icon required by flutter_background_service
d = root / "app/src/main/res/drawable"
d.mkdir(parents=True, exist_ok=True)
(d / "ic_bg_service_small.xml").write_text("""<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#FFFFFFFF"
        android:pathData="M12,2C8.13,2 5,5.13 5,9c0,5.25 7,13 7,13s7,-7.75 7,-13c0,-3.87 -3.13,-7 -7,-7zM12,11.5c-1.38,0 -2.5,-1.12 -2.5,-2.5s1.12,-2.5 2.5,-2.5 2.5,1.12 2.5,2.5 -1.12,2.5 -2.5,2.5z"/>
</vector>
""")

print("android/ patched OK")
