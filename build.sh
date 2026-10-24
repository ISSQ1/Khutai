#!/bin/bash
#
# بناء «خُطاي» وتوقيعه محليًا.
#
#   ./build.sh            بناء فقط
#   ./build.sh --install  بناء ثم استبدال النسخة في مجلد Applications
#   ./build.sh --package  بناء ثم إنتاج Khutai.zip مع بصمة SHA-256 للنشر
#
set -euo pipefail
cd "$(dirname "$0")"

PROJECT="LotusPlanner.xcodeproj"
BUILD_DIR="build/ReleaseBuild"
APP="$BUILD_DIR/Release/LotusPlanner.app"
INSTALLED="/Applications/خُطاي.app"

echo "── ١/٤ البناء ──"
# ملاحظة: App Groups تجعل Xcode يطالب بملف تعريف (provisioning profile)، وهو
# يتطلب حساب Apple Developer مدفوعًا. نعطّل التوقيع أثناء البناء ثم نوقّع
# محليًا في الخطوة التالية.
#
# ونبني نسخة شاملة (Apple Silicon وIntel) حتى تعمل على أي ماك بنظام macOS 14 أو أحدث.
#
# وتعطيل رموز التنقيح يمنع تضمين المسار المطلق لمجلد المطوّر داخل الملف
# التنفيذي — وإلا انكشف اسم المستخدم على جهاز من يبني النسخة المنشورة.
xcodebuild \
  -project "$PROJECT" \
  -target LotusPlanner \
  -configuration Release \
  SYMROOT="$BUILD_DIR" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  GCC_GENERATE_DEBUGGING_SYMBOLS=NO \
  DEBUG_INFORMATION_FORMAT=dwarf \
  build > /tmp/khutai-build.log 2>&1 \
  || { echo "❌ فشل البناء. آخر الأسطر:"; tail -25 /tmp/khutai-build.log; exit 1; }

echo "── ٢/٤ إزالة رموز التنقيح المتبقية ──"
strip -S "$APP/Contents/MacOS/LotusPlanner" 2>/dev/null || true
strip -S "$APP/Contents/PlugIns/LotusPlannerWidget.appex/Contents/MacOS/LotusPlannerWidget" 2>/dev/null || true

echo "── ٣/٤ التوقيع المحلي ──"
# الترتيب مهم: الإضافة أولًا ثم التطبيق الحاوي لها.
codesign --force --sign - \
  --entitlements LotusPlannerWidget/LotusPlannerWidget.entitlements \
  "$APP/Contents/PlugIns/LotusPlannerWidget.appex"
codesign --force --sign - \
  --entitlements LotusPlanner/LotusPlanner.entitlements \
  "$APP"
codesign --verify --deep --strict "$APP" && echo "   التوقيع سليم"

echo "── ٤/٤ فحص تسرّب المسارات الشخصية ──"
LEAKS=$(strings "$APP/Contents/MacOS/LotusPlanner" 2>/dev/null | grep -c "^/Users/" || true)
if [ "$LEAKS" -gt 0 ]; then
  echo "   ⚠️  تحذير: عُثر على $LEAKS مسارًا يبدأ بـ /Users/ داخل الملف التنفيذي."
  echo "       هذه المسارات تكشف اسم المستخدم على جهاز البناء. عيّنة:"
  strings "$APP/Contents/MacOS/LotusPlanner" | grep "^/Users/" | head -3 | sed 's/^/       /'
else
  echo "   ✅ نظيف — لا مسارات شخصية داخل الملف التنفيذي"
fi

echo
echo "✅ جاهز: $APP"
echo "   المعماريات: $(lipo -archs "$APP/Contents/MacOS/LotusPlanner" 2>/dev/null || echo غير معروفة)"

if [[ "${1:-}" == "--install" ]]; then
  echo
  echo "── التركيب ──"
  osascript -e 'quit app "خُطاي"' >/dev/null 2>&1 || true
  sleep 1
  rm -rf "$INSTALLED"
  cp -R "$APP" "$INSTALLED"
  # إعادة التسجيل وتحديث خدمة الودجتات، وإلا ظل macOS يشغّل النسخة القديمة.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALLED"
  killall chronod 2>/dev/null || true
  sleep 2
  open "$INSTALLED"
  echo "✅ رُكّب في $INSTALLED"
  echo "   إن لم يتغيّر شكل الودجت: احذفه من سطح المكتب وأعد إضافته."
fi

if [[ "${1:-}" == "--package" ]]; then
  echo
  echo "── التغليف للنشر ──"
  rm -rf dist && mkdir -p dist
  cp -R "$APP" "dist/خُطاي.app"
  ( cd dist && ditto -c -k --keepParent "خُطاي.app" "Khutai.zip" && rm -rf "خُطاي.app" )
  echo
  echo "✅ dist/Khutai.zip"
  echo
  echo "انشر هذه البصمة في صفحة الإصدار ليتحقق منها المستخدمون:"
  shasum -a 256 dist/Khutai.zip
fi
