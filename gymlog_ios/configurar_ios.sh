#!/bin/bash
# Prepara el proyecto GymLog para iPhone. Ejecutar en una Mac:  bash configurar_ios.sh com.tunombre
set -e
ORG="${1:-com.gymlog}"
cd "$(dirname "$0")"

command -v flutter >/dev/null || { echo "Falta Flutter: https://docs.flutter.dev/get-started/install/macos"; exit 1; }
command -v pod >/dev/null || { echo "Falta CocoaPods: ejecuta  brew install cocoapods"; exit 1; }

# Respaldo del código, por si flutter create tocara lib/main.dart
cp lib/main.dart /tmp/gymlog_main.dart.bak
flutter create --platforms=ios --org "$ORG" --project-name gymlog .
cp /tmp/gymlog_main.dart.bak lib/main.dart
rm -f test/widget_test.dart

flutter pub get
dart run flutter_launcher_icons

# Nombre que se ve bajo el icono
PLIST=ios/Runner/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName GymLog" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string GymLog" "$PLIST"

(cd ios && pod install)
echo ""
echo "Listo. Se abrira Xcode: configura la firma (ver LEEME.txt, paso 3)."
open ios/Runner.xcworkspace
