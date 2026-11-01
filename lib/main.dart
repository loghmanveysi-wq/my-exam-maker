import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:archive/archive.dart' show Archive, ArchiveFile, ZipEncoder;
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:flutter_poolakey/flutter_poolakey.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

late SharedPreferences prefs;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  prefs = await SharedPreferences.getInstance();
  runApp(const App());
}

// نام برنامه پایین هر صفحه‌ی PDF و Word (کنار لوگو)
const kSignature = 'آزمون بساز';

Future<Uint8List?> loadLogo() async {
  try {
    return (await rootBundle.load('assets/logo.png')).buffer.asUint8List();
  } catch (_) {
    return null;
  }
}

const kBlue = Color(0xFF1565C0);
const kLabels = ['الف', 'ب', 'ج', 'د'];
const kLatin = ['A', 'B', 'C', 'D'];
const kCm = 28.3465; // هر سانتی‌متر چند پوینت

// ---------------- اعداد ----------------
String fa(String s) {
  const e = '0123456789';
  const f = '۰۱۲۳۴۵۶۷۸۹';
  for (var i = 0; i < 10; i++) {
    s = s.replaceAll(e[i], f[i]);
  }
  return s;
}

// نقطه اعشار به اسلش تبدیل می‌شود: ۲/۵
String num2(double p) {
  final r = (p * 100).round() / 100; // حذف خطای اعشاری جمع نمرات
  final t = r % 1 == 0
      ? r.toInt().toString()
      : r.toString().replaceFirst(RegExp(r'0+$'), '');
  return fa(t).replaceAll('.', '/');
}

String toEn(String s) {
  const f = '۰۱۲۳۴۵۶۷۸۹';
  const a = '٠١٢٣٤٥٦٧٨٩';
  for (var i = 0; i < 10; i++) {
    s = s.replaceAll(f[i], '$i').replaceAll(a[i], '$i');
  }
  return s
      .replaceAll('٫', '.')
      .replaceAll('/', '.')
      .replaceAll(',', '.')
      .replaceAll('،', '.');
}

// جهت متن: فارسی/عربی راست‌به‌چپ، انگلیسی چپ‌به‌راست
bool isRtl(String s) {
  for (final r in s.runes) {
    if ((r >= 0x0600 && r <= 0x06FF) ||
        (r >= 0x0750 && r <= 0x077F) ||
        (r >= 0xFB50 && r <= 0xFDFF) ||
        (r >= 0xFE70 && r <= 0xFEFF)) {
      return true;
    }
    if ((r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A)) return false;
  }
  return true;
}

// ---------------- محدودیت رایگان و خرید از کافه‌بازار ----------------
const kFreeExams = 3;
// حالت تست: true = محدودیت ۳ ساخت رایگان برداشته می‌شود. قبل از انتشار false کنید.
const kTestMode = false;
const kProductId = 'premium_full';
const kBazaarKey =
    'MIHNMA0GCSqGSIb3DQEBAQUAA4G7ADCBtwKBrwC20MJaoLt95AGylGqEsm4zPphkWjbOAV3+M7Dft1cXEgrcIOz/awkVP3archjfG+ub9plvQLfstgLqttR3Zw5bP/e2ibmM8mFxrE+jWsm/sCJ6Gs1lyZ/S8BuYdzPoZRUfpNas1Avsn0FTGBmVLR3fSG3uWbxPLjMUeIencsOs67Jsgsv2Ew4mZMz4X9+/1CrTtNVZyIZsIW/UuyCPv8OC4S/cJA6FmCQavTC/tn0CAwEAAQ==';

class Lic {
  static const _kPrem = 'is_premium';
  static const _kUsed = 'used_exams';

  static bool get premium =>
      prefs.getString('session') == 'owner' || (prefs.getBool(_kPrem) ?? false);
  static Set<String> _used() => (prefs.getStringList(_kUsed) ?? []).toSet();
  static int get usedCount => _used().length;
  static int get left => math.max(0, kFreeExams - usedCount);

  // هر خروجی (PDF یا Word) یک ساخت حساب می‌شود، حتی اگر آزمون تکراری باشد
  static bool canExport(String id) =>
      kTestMode || premium || usedCount < kFreeExams;

  static Future<void> register(String id) async {
    if (premium) return;
    final u = _used()..add('$id|${DateTime.now().microsecondsSinceEpoch}');
    await prefs.setStringList(_kUsed, u.toList());
  }

  static Future<bool> _connect() async {
    final c = Completer<bool>();
    try {
      await FlutterPoolakey.connect(
        kBazaarKey,
        onSucceed: () {
          if (!c.isCompleted) c.complete(true);
        },
        onFailed: () {
          if (!c.isCompleted) c.complete(false);
        },
        onDisconnected: () {},
      );
    } catch (_) {
      return false;
    }
    return c.future.timeout(const Duration(seconds: 10), onTimeout: () => false);
  }

  static Future<void> _disconnect() async {
    try {
      await FlutterPoolakey.disconnect();
    } catch (_) {}
  }

  // null یعنی خرید موفق بود؛ در غیر این صورت متن خطا
  static Future<String?> buy() async {
    if (!await _connect()) {
      return 'اتصال به کافه‌بازار برقرار نشد. مطمئن شوید کافه‌بازار نصب است و وارد حساب خود شده‌اید.';
    }
    try {
      await FlutterPoolakey.purchase(kProductId);
      await prefs.setBool(_kPrem, true);
      return null;
    } catch (_) {
      return 'خرید انجام نشد.';
    } finally {
      await _disconnect();
    }
  }

  static Future<bool> restore() async {
    if (!await _connect()) return false;
    try {
      final p = await FlutterPoolakey.queryPurchasedProduct(kProductId);
      if (p != null) {
        await prefs.setBool(_kPrem, true);
        return true;
      }
      return false;
    } catch (_) {
      return false;
    } finally {
      await _disconnect();
    }
  }
}

// ---------------- حساب کاربری ----------------
const kSalt = 'azmoon-besaz|';
const kAdminEmailHash =
    '7d1d80643d8c7ef1e91ea9240b7ac321524c1231e357c08ef04d5108c13aff18';
const kAdminPassHash =
    '8c55c67afba77902ef01876e781c027ba8559f5ad0185346a7efd321f8c72341';

const kOwnerUserHash =
    'a3eef4c63c2730a3775b80757a7a1b62aecadba47f2a68fee5f0c63bb5628a4a';
const kOwnerPassHash =
    '8c55c67afba77902ef01876e781c027ba8559f5ad0185346a7efd321f8c72341';

String sha(String s) => sha256.convert(utf8.encode('$kSalt$s')).toString();

class AppUser {
  String first, last, username, mobile, email, salt, hash, created;
  AppUser({
    required this.first,
    required this.last,
    required this.username,
    required this.mobile,
    required this.email,
    required this.salt,
    required this.hash,
    required this.created,
  });
  String get full => '$first $last';
  Map<String, dynamic> toJson() => {
        'first': first,
        'last': last,
        'username': username,
        'mobile': mobile,
        'email': email,
        'salt': salt,
        'hash': hash,
        'created': created,
      };
  factory AppUser.fromJson(Map<String, dynamic> j) => AppUser(
        first: j['first'] ?? '',
        last: j['last'] ?? '',
        username: j['username'] ?? '',
        mobile: j['mobile'] ?? '',
        email: j['email'] ?? '',
        salt: j['salt'] ?? '',
        hash: j['hash'] ?? '',
        created: j['created'] ?? '',
      );
}

List<AppUser> loadUsers() {
  final raw = prefs.getString('users');
  if (raw == null) return [];
  return (jsonDecode(raw) as List).map((e) => AppUser.fromJson(e)).toList();
}

void saveUsers(List<AppUser> l) =>
    prefs.setString('users', jsonEncode(l.map((e) => e.toJson()).toList()));

Future<void> openUrl(BuildContext c, String url) async {
  try {
    final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!ok) throw Exception('x');
  } catch (_) {
    if (c.mounted) {
      ScaffoldMessenger.of(c)
          .showSnackBar(const SnackBar(content: Text('باز کردن لینک ممکن نشد')));
    }
  }
}

// ---------------- انتخاب تصویر (هر فرمتی) ----------------
Future<String?> pickImage() async {
  final x = await ImagePicker()
      .pickImage(source: ImageSource.gallery, maxWidth: 1600, imageQuality: 85);
  if (x == null) return null;
  Uint8List bytes = await x.readAsBytes();
  var ext = 'png';
  final isJpg = bytes.length > 3 && bytes[0] == 0xFF && bytes[1] == 0xD8;
  final isPng = bytes.length > 3 && bytes[0] == 0x89 && bytes[1] == 0x50;
  if (isJpg) {
    ext = 'jpg';
  } else if (!isPng) {
    final im = await decodeImageFromList(bytes);
    final bd = await im.toByteData(format: ui.ImageByteFormat.png);
    if (bd == null) return null;
    bytes = bd.buffer.asUint8List();
  }
  final dir = await getApplicationDocumentsDirectory();
  final path = '${dir.path}/img_${DateTime.now().microsecondsSinceEpoch}.$ext';
  await File(path).writeAsBytes(bytes, flush: true);
  return path;
}

Future<Size?> imgSize(String path) async {
  try {
    final im = await decodeImageFromList(await File(path).readAsBytes());
    return Size(im.width.toDouble(), im.height.toDouble());
  } catch (_) {
    return null;
  }
}

class Fx {
  final Uint8List bytes;
  final double w, h;
  final bool rtl; // خط حاوی فارسی است → راست‌چین
  Fx(this.bytes, this.w, this.h, {this.rtl = false});
}

class QFx {
  final List<Fx> formulas; // فرمول‌های جداگانه‌ی قدیمی
  final Map<int, Fx> lines; // خطوط متن سؤال که فرمول درون‌خطی دارند
  QFx(this.formulas, this.lines);
}

const kFxScale = 13 / 30;

// ---------------- فرمول درون‌خطی و متن فارسی ----------------
const kFxFont = 'FxFont';
Future<void>? _fxFontFuture;
Future<void> ensureFxFont() => _fxFontFuture ??= _loadFxFont();

Future<void> _loadFxFont() async {
  final loader = FontLoader(kFxFont);
  var ok = false;
  for (final a in ['assets/fonts/BNazanin.ttf', 'assets/fonts/Vazir.ttf']) {
    try {
      final d = await rootBundle.load(a);
      loader.addFont(Future.value(d));
      ok = true;
      break;
    } catch (_) {}
  }
  if (ok) {
    try {
      await loader.load();
    } catch (_) {}
  }
}

final _faRun = RegExp(
    r'[\u0600-\u06FF\u200c\u200f]+(?:[ \u00a0]+[\u0600-\u06FF\u200c\u200f]+)*');

bool hasPersian(String s) => RegExp(r'[\u0600-\u06FF]').hasMatch(s);

// جداسازی متن سؤال به بخش‌های عادی و فرمول ($...$)
List<(bool, String)> splitDollar(String s) {
  final out = <(bool, String)>[];
  var i = 0;
  while (i < s.length) {
    final a = s.indexOf(r'$', i);
    if (a < 0) break;
    final b = s.indexOf(r'$', a + 1);
    if (b < 0) break;
    out.add((false, s.substring(i, a)));
    out.add((true, s.substring(a + 1, b)));
    i = b + 1;
  }
  out.add((false, s.substring(i)));
  return out.where((e) => e.$2.trim().isNotEmpty).toList();
}

bool hasMathMark(String line) => splitDollar(line).any((e) => e.$1);

bool lineRtl(String line) =>
    isRtl(splitDollar(line).where((e) => !e.$1).map((e) => e.$2).join(' '));

// ساخت ویجت یک خط: کلمات فارسی با متن عادی (راست‌چین و متصل)، فرمول‌ها با Math
Widget fxLineWidget(String src,
    {required bool textMode, double fs = 30, double? maxW}) {
  final parts = textMode ? splitDollar(src) : <(bool, String)>[(true, src)];
  final rtl = textMode ? lineRtl(src) : hasPersian(src);
  final kids = <Widget>[];

  Widget mathW(String t) => Directionality(
        textDirection: TextDirection.ltr,
        child: Math.tex(t, textStyle: TextStyle(fontSize: fs, color: Colors.black)),
      );

  void word(String w) => kids.add(Text(w,
      textDirection: isRtl(w) ? TextDirection.rtl : TextDirection.ltr,
      style: TextStyle(
          fontSize: fs, color: Colors.black, fontFamily: kFxFont, height: 1.2)));

  void words(String t) {
    for (final w in t.split(RegExp(r'[ \u00a0\t]+'))) {
      if (w.isNotEmpty) word(w);
    }
  }

  void mathSeg(String m) {
    var last = 0;
    for (final mt in _faRun.allMatches(m)) {
      final pre = m.substring(last, mt.start).trim();
      if (pre.isNotEmpty) kids.add(mathW(pre));
      words(mt.group(0)!);
      last = mt.end;
    }
    final tail = m.substring(last).trim();
    if (tail.isNotEmpty) kids.add(mathW(tail));
  }

  for (final p in parts) {
    if (p.$1) {
      mathSeg(p.$2);
    } else {
      words(p.$2);
    }
  }

  if (kids.isEmpty) return const SizedBox.shrink();
  Widget child;
  if (kids.length == 1) {
    child = kids.first;
  } else {
    child = Wrap(
      spacing: fs * 0.3,
      runSpacing: fs * 0.2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: kids,
    );
    if (maxW != null) child = ConstrainedBox(constraints: BoxConstraints(maxWidth: maxW), child: child);
  }
  return Directionality(
      textDirection: rtl ? TextDirection.rtl : TextDirection.ltr, child: child);
}

// ---------------- مدل سؤال ----------------
class Q {
  String type; // mc, tf, desc
  String text;
  String formula;
  List<String> options;
  double points;
  String? image;
  double imgW;
  double imgH;
  String imgAlign; // l, c, r
  int lines; // تعداد خط پاسخ (تشریحی)
  bool imgManual; // تغییر دستی اندازه‌ی تصویرِ سؤال تصویری
  Q({
    required this.type,
    required this.text,
    this.formula = '',
    List<String>? options,
    this.points = 1,
    this.image,
    this.imgW = 10,
    this.imgH = 6,
    this.imgAlign = 'c',
    this.lines = 0,
    this.imgManual = false,
  }) : options = options ?? ['', '', '', ''];
  Map<String, dynamic> toJson() => {
        'type': type,
        'text': text,
        'formula': formula,
        'options': options,
        'points': points,
        'image': image,
        'imgW': imgW,
        'imgH': imgH,
        'imgAlign': imgAlign,
        'lines': lines,
        'imgManual': imgManual,
      };
  factory Q.fromJson(Map<String, dynamic> j) => Q(
        type: j['type'],
        text: j['text'] ?? '',
        formula: j['formula'] ?? '',
        options: List<String>.from(j['options']),
        points: (j['points'] as num).toDouble(),
        image: j['image'],
        imgW: (j['imgW'] as num?)?.toDouble() ?? 10,
        imgH: (j['imgH'] as num?)?.toDouble() ?? 6,
        imgAlign: j['imgAlign'] ?? 'c',
        lines: (j['lines'] as num?)?.toInt() ?? 0,
        imgManual: j['imgManual'] == true,
      );
}

// ---------------- مدل سربرگ ----------------
const hdrLabels = {
  'bism': 'عبارت بالای برگه',
  'ministry': 'وزارت',
  'province': 'اداره کل آموزش و پرورش استان',
  'district': 'مدیریت آموزش و پرورش شهرستان',
  'school': 'نام آموزشگاه',
  'level': 'مقطع',
  'subject': 'درس',
  'grade': 'پایه',
  'teacher': 'نام دبیر',
  'round': 'نوبت امتحان',
  'date': 'تاریخ امتحان',
  'duration': 'زمان پاسخگویی (مثلاً ۶۰ دقیقه)',
  'start': 'ساعت شروع',
  'pages': 'تعداد صفحه',
};

const hdrDefaults = {
  'bism': 'بسمه تعالی',
  'ministry': 'وزارت آموزش و پرورش',
  'province': 'اداره کل آموزش و پرورش استان ......',
  'district': 'مدیریت آموزش و پرورش شهرستان ......',
  'level': 'متوسطه دوره اول',
};

class Hdr {
  final Map<String, String> m;
  Hdr([Map<String, String>? v])
      : m = {
          for (final k in hdrLabels.keys) k: v?[k] ?? hdrDefaults[k] ?? ''
        };
  String operator [](String k) => m[k] ?? '';
  Map<String, dynamic> toJson() => m;
  factory Hdr.fromJson(Map<String, dynamic> j) {
    final v = <String, String>{};
    for (final k in hdrLabels.keys) {
      if (j[k] is String) v[k] = j[k] as String;
    }
    if (!v.containsKey('school') && j['org'] is String) {
      v['school'] = j['org'] as String;
    }
    return Hdr(v);
  }

  List<String> get midLines => [
        this['bism'],
        this['ministry'],
        this['province'],
        this['district'],
        'آموزشگاه: ${this['school'].isEmpty ? '........' : this['school']}',
        this['level'],
        if (this['subject'].isNotEmpty) 'درس: ${this['subject']}',
      ].where((e) => e.isNotEmpty).toList();

  List<String> get rightRows => [
        'نام و نام خانوادگی: ................',
        'نام پدر: ................',
        'شماره دانش‌آموزی: ................',
        'نام کلاس: ................',
        'پایه: ${this['grade']}      نام دبیر: ${this['teacher']}',
      ];

  List<String> get leftRows => [
        'نوبت امتحان: ${this['round']}',
        'تاریخ امتحان: ${this['date']}',
        'زمان پاسخگویی: ${this['duration']}',
        'ساعت شروع: ${this['start']}',
        'تعداد صفحه: ${this['pages']}',
      ];
}

String typeName(String t) =>
    t == 'mc' ? 'چهارگزینه‌ای' : (t == 'tf' ? 'صحیح/غلط' : 'تشریحی');

// ---------------- ابزارهای Word ----------------
String esc(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

String rp(String s, {int sz = 22, bool b = false, bool rtl = true}) =>
    '<w:r><w:rPr><w:rFonts w:ascii="Tahoma" w:hAnsi="Tahoma" w:cs="Tahoma"/>'
    '${b ? '<w:b/><w:bCs/>' : ''}<w:sz w:val="$sz"/><w:szCs w:val="$sz"/>${rtl ? '<w:rtl/>' : ''}</w:rPr>'
    '<w:t xml:space="preserve">${esc(s)}</w:t></w:r>';

String pp(String inner, {bool center = false, bool rtl = true}) =>
    '<w:p><w:pPr>${rtl ? '<w:bidi/>' : ''}<w:spacing w:before="40" w:after="40"/>'
    '${center ? '<w:jc w:val="center"/>' : ''}</w:pPr>$inner</w:p>';

String ruledLine() =>
    '<w:p><w:pPr><w:pBdr><w:bottom w:val="single" w:sz="4" w:space="1" w:color="999999"/>'
    '<w:between w:val="single" w:sz="4" w:space="1" w:color="999999"/></w:pBdr>'
    '<w:spacing w:before="200" w:after="0"/></w:pPr></w:p>';

String tcX(String inner, int w,
        {String vm = '', bool td = false, String va = 'top'}) =>
    '<w:tc><w:tcPr><w:tcW w:w="$w" w:type="dxa"/>$vm'
    '${td ? '<w:textDirection w:val="btLr"/>' : ''}<w:vAlign w:val="$va"/></w:tcPr>$inner</w:tc>';

String trX(String cells, {int h = 0}) =>
    '<w:tr>${h > 0 ? '<w:trPr><w:cantSplit/><w:trHeight w:val="$h" w:hRule="atLeast"/></w:trPr>' : ''}$cells</w:tr>';

String tblPr(int inner) =>
    '<w:tblPr><w:bidiVisual/><w:tblW w:w="10700" w:type="dxa"/><w:tblBorders>'
    '<w:top w:val="single" w:sz="18" w:space="0" w:color="000000"/>'
    '<w:left w:val="single" w:sz="18" w:space="0" w:color="000000"/>'
    '<w:bottom w:val="single" w:sz="18" w:space="0" w:color="000000"/>'
    '<w:right w:val="single" w:sz="18" w:space="0" w:color="000000"/>'
    '<w:insideH w:val="single" w:sz="$inner" w:space="0" w:color="000000"/>'
    '<w:insideV w:val="single" w:sz="$inner" w:space="0" w:color="000000"/>'
    '</w:tblBorders><w:tblLayout w:type="fixed"/></w:tblPr>';

int fitSz(String s, int sz, int n) =>
    s.length <= n ? sz : math.max(12, (sz * n / s.length).floor());

PreferredSizeWidget bar(String t, {List<Widget>? actions}) => AppBar(
      foregroundColor: Colors.white,
      title: Text(t, style: const TextStyle(fontWeight: FontWeight.bold)),
      flexibleSpace: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(colors: [Color(0xFF1E88E5), Color(0xFF0D47A1)]),
        ),
      ),
      actions: actions,
    );

Widget actBtn(IconData i, String label, VoidCallback f) => InkWell(
      onTap: f,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(i, size: 24, color: Colors.white),
            const SizedBox(height: 2),
            Text(label,
                style: const TextStyle(
                    color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );

Widget field(TextEditingController c, String label,
        {int lines = 1, TextInputType? kb, void Function(String)? onChanged}) =>
    Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        minLines: lines,
        maxLines: lines + 3,
        keyboardType: kb,
        onChanged: onChanged,
        decoration: InputDecoration(
          filled: true,
          fillColor: Colors.white,
          labelText: label,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
    );

// ---------------- برنامه ----------------
class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'آزمون بساز',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: kBlue),
        scaffoldBackgroundColor: const Color(0xFFEAF2FF),
      ),
      builder: (c, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
      home: const Root(),
    );
  }
}

class Root extends StatefulWidget {
  const Root({super.key});
  @override
  State<Root> createState() => _RootState();
}

class _RootState extends State<Root> {
  String? session = prefs.getString('session');

  void login(String s) {
    prefs.setString('session', s);
    setState(() => session = s);
  }

  void logout() {
    prefs.remove('session');
    setState(() => session = null);
  }

  @override
  Widget build(BuildContext context) {
    if (session == null) return AuthScreen(onLogin: login);
    return Shell(key: ValueKey(session), session: session!, onLogout: logout);
  }
}

// ---------------- ثبت‌نام و ورود ----------------
class AuthScreen extends StatefulWidget {
  final void Function(String) onLogin;
  const AuthScreen({super.key, required this.onLogin});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool signup = false;
  bool hide = true;
  String err = '';
  final first = TextEditingController();
  final last = TextEditingController();
  final user = TextEditingController();
  final mobile = TextEditingController();
  final email = TextEditingController();
  final pass = TextEditingController();

  void doLogin() {
    final em = email.text.trim().toLowerCase();
    final pw = pass.text;
    if (em.isEmpty || pw.isEmpty) {
      setState(() => err = 'ایمیل و رمز عبور را وارد کنید');
      return;
    }
    if (sha(em) == kAdminEmailHash &&
        (sha(pw) == kAdminPassHash || sha(toEn(pw)) == kAdminPassHash)) {
      widget.onLogin('admin');
      return;
    }
    if (sha(em) == kOwnerUserHash &&
        (sha(pw) == kOwnerPassHash || sha(toEn(pw)) == kOwnerPassHash)) {
      widget.onLogin('owner');
      return;
    }
    final u = loadUsers().where((x) => x.email == em).toList();
    if (u.isNotEmpty && sha('${u.first.salt}|$pw') == u.first.hash) {
      widget.onLogin(em);
      return;
    }
    setState(() => err = 'ایمیل یا رمز عبور اشتباه است');
  }

  void doSignup() {
    final f = first.text.trim();
    final l = last.text.trim();
    final un = user.text.trim();
    final mo = toEn(mobile.text.trim()).replaceAll('.', '');
    final em = email.text.trim().toLowerCase();
    final pw = pass.text;
    if (f.isEmpty || l.isEmpty || un.isEmpty || mo.isEmpty || em.isEmpty || pw.isEmpty) {
      setState(() => err = 'همه‌ی فیلدها را پر کنید');
      return;
    }
    if (un.length < 3 || un.contains(' ')) {
      setState(() => err = 'نام کاربری حداقل ۳ حرف و بدون فاصله باشد');
      return;
    }
    if (!RegExp(r'^09\d{9}$').hasMatch(mo)) {
      setState(() => err = 'شماره موبایل باید مثل 09123456789 باشد');
      return;
    }
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(em)) {
      setState(() => err = 'ایمیل معتبر نیست');
      return;
    }
    if (pw.length < 6) {
      setState(() => err = 'رمز عبور حداقل ۶ کاراکتر باشد');
      return;
    }
    final users = loadUsers();
    if (sha(em) == kAdminEmailHash ||
        users.any((x) => x.email == em)) {
      setState(() => err = 'این ایمیل قبلاً ثبت شده است');
      return;
    }
    if (users.any((x) => x.username.toLowerCase() == un.toLowerCase())) {
      setState(() => err = 'این نام کاربری قبلاً گرفته شده است');
      return;
    }
    final rnd = math.Random.secure();
    final salt = base64Url.encode(List<int>.generate(12, (_) => rnd.nextInt(256)));
    users.add(AppUser(
      first: f,
      last: l,
      username: un,
      mobile: mo,
      email: em,
      salt: salt,
      hash: sha('$salt|$pw'),
      created: DateTime.now().toIso8601String(),
    ));
    saveUsers(users);
    widget.onLogin(em);
  }

  Widget fld(TextEditingController c, String label,
          {TextInputType? kb, bool pwd = false, bool ltr = false}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          keyboardType: kb,
          obscureText: pwd && hide,
          textDirection: ltr ? TextDirection.ltr : null,
          decoration: InputDecoration(
            labelText: label,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            suffixIcon: pwd
                ? IconButton(
                    icon: Icon(hide ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => hide = !hide),
                  )
                : null,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF1E88E5), Color(0xFF0D47A1)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(children: [
                const Icon(Icons.edit_note, size: 72, color: Colors.white),
                const Text('آزمون بساز',
                    style: TextStyle(
                        color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                Card(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(children: [
                      SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(value: false, label: Text('ورود')),
                          ButtonSegment(value: true, label: Text('ثبت‌نام')),
                        ],
                        selected: {signup},
                        onSelectionChanged: (s) =>
                            setState(() {
                              signup = s.first;
                              err = '';
                            }),
                      ),
                      const SizedBox(height: 16),
                      if (signup) ...[
                        fld(first, 'نام'),
                        fld(last, 'نام خانوادگی'),
                        fld(user, 'نام کاربری', ltr: true),
                        fld(mobile, 'شماره موبایل',
                            kb: TextInputType.phone, ltr: true),
                      ],
                      fld(email, 'ایمیل',
                          kb: TextInputType.emailAddress, ltr: true),
                      fld(pass, 'رمز عبور', pwd: true, ltr: true),
                      if (err.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Text(err,
                              style: const TextStyle(color: Colors.redAccent)),
                        ),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                              backgroundColor: kBlue,
                              padding: const EdgeInsets.all(14)),
                          onPressed: signup ? doSignup : doLogin,
                          child: Text(signup ? 'ثبت‌نام' : 'ورود',
                              style: const TextStyle(fontSize: 16)),
                        ),
                      ),
                    ]),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------- قاب اصلی با نوار پایین ----------------
class Shell extends StatefulWidget {
  final String session;
  final VoidCallback onLogout;
  const Shell({super.key, required this.session, required this.onLogout});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int idx = 1;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: idx, children: [
        ProfilePage(session: widget.session, onLogout: widget.onLogout),
        Home(uid: widget.session),
        const ContactPage(),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: idx,
        onDestinationSelected: (i) => setState(() => idx = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.person), label: 'پروفایل'),
          NavigationDestination(icon: Icon(Icons.home), label: 'خانه'),
          NavigationDestination(
              icon: Icon(Icons.support_agent), label: 'ارتباط با ما'),
        ],
      ),
    );
  }
}

// ---------------- پروفایل ----------------
class ProfilePage extends StatelessWidget {
  final String session;
  final VoidCallback onLogout;
  const ProfilePage({super.key, required this.session, required this.onLogout});

  @override
  Widget build(BuildContext context) {
    final admin = session == 'admin';
    AppUser? u;
    for (final x in loadUsers()) {
      if (x.email == session) u = x;
    }
    final name = admin
        ? 'مدیر سیستم'
        : (session == 'owner' ? 'Loghman' : (u?.full ?? ''));
    Widget row(IconData i, String label, String v) => Card(
          child: ListTile(
            leading: Icon(i, color: kBlue),
            title: Text(label, style: const TextStyle(fontSize: 12)),
            subtitle: Text(v, style: const TextStyle(fontSize: 16)),
          ),
        );
    return Scaffold(
      appBar: bar('پروفایل'),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Center(
          child: CircleAvatar(
            radius: 44,
            backgroundColor: kBlue,
            foregroundColor: Colors.white,
            child: Text(name.isEmpty ? '?' : name.characters.first,
                style: const TextStyle(fontSize: 36)),
          ),
        ),
        const SizedBox(height: 8),
        Center(
            child: Text(name,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
        const SizedBox(height: 16),
        if (!admin && u != null) ...[
          row(Icons.alternate_email, 'نام کاربری', u.username),
          row(Icons.phone_android, 'شماره موبایل', fa(u.mobile)),
          row(Icons.email, 'ایمیل', u.email),
        ],
        if (admin)
          Card(
            color: const Color(0xFFFFF3E0),
            child: ListTile(
              leading: const Icon(Icons.groups, color: Color(0xFFEF6C00)),
              title: const Text('کاربران ثبت‌نام‌شده'),
              subtitle: Text('تعداد: ${fa('${loadUsers().length}')}'),
              trailing: const Icon(Icons.chevron_left),
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const UsersPage())),
            ),
          ),
        const SizedBox(height: 16),
        FilledButton.icon(
          style: FilledButton.styleFrom(
              backgroundColor: Colors.redAccent, padding: const EdgeInsets.all(14)),
          onPressed: onLogout,
          icon: const Icon(Icons.logout),
          label: const Text('خروج از حساب'),
        ),
      ]),
    );
  }
}

class UsersPage extends StatelessWidget {
  const UsersPage({super.key});
  @override
  Widget build(BuildContext context) {
    final users = loadUsers();
    return Scaffold(
      appBar: bar('کاربران ثبت‌نام‌شده'),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text(
              'این فهرست فقط کاربرانی را نشان می‌دهد که روی همین دستگاه ثبت‌نام کرده‌اند.',
              style: TextStyle(fontSize: 12, color: Colors.black54)),
        ),
        if (users.isEmpty) const Center(child: Text('هنوز کاربری ثبت‌نام نکرده است')),
        for (final u in users)
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(u.full,
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text('نام کاربری: ${u.username}'),
                Text('موبایل: ${fa(u.mobile)}'),
                Text('ایمیل: ${u.email}'),
                Text(
                    'تاریخ ثبت‌نام: ${fa(u.created.length >= 10 ? u.created.substring(0, 10) : u.created)}',
                    style: const TextStyle(color: Colors.black54, fontSize: 12)),
              ]),
            ),
          ),
      ]),
    );
  }
}

// ---------------- ارتباط با ما ----------------
class ContactPage extends StatelessWidget {
  const ContactPage({super.key});
  @override
  Widget build(BuildContext context) {
    Widget btn(IconData i, String t, String sub, Color c, String url) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => openUrl(context, url),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                  color: c, borderRadius: BorderRadius.circular(16)),
              child: Row(children: [
                Icon(i, color: Colors.white, size: 30),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(t,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold)),
                    Text(sub,
                        textDirection: TextDirection.ltr,
                        style: const TextStyle(color: Colors.white70)),
                  ]),
                ),
                const Icon(Icons.chevron_left, color: Colors.white),
              ]),
            ),
          ),
        );
    return Scaffold(
      appBar: bar('ارتباط با ما'),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
                colors: [Color(0xFF1E88E5), Color(0xFF0D47A1)]),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Column(children: [
            Icon(Icons.favorite, color: Colors.white, size: 40),
            SizedBox(height: 8),
            Text('با ما در ارتباط باشید',
                style: TextStyle(
                    color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
            SizedBox(height: 8),
            Text(
              'نظرات، پیشنهادها و انتقادات ارزشمند شما، چراغ راه بهبود «آزمون بساز» است. '
              'در این بخش، دیدگاه‌های خود را با ما در میان بگذارید؛ '
              'با افتخار می‌شنویم و در اسرع وقت پاسخگوی شما هستیم.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, height: 1.8),
            ),
          ]),
        ),
        const SizedBox(height: 20),
        btn(Icons.chat, 'پیام در روبیکا', '@Veysi_ai', const Color(0xFF8E24AA),
            'https://rubika.ir/Veysi_ai'),
        btn(Icons.phone, 'تماس تلفنی', '09189301521', const Color(0xFF2E7D32),
            'tel:09189301521'),
        btn(Icons.sms, 'ارسال پیامک', '09189301521', const Color(0xFFEF6C00),
            'sms:09189301521'),
      ]),
    );
  }
}

// ---------------- خانه: ساخت آزمون ----------------
class Home extends StatefulWidget {
  final String uid;
  const Home({super.key, required this.uid});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  List<Q> qs = [];
  Hdr hdr = Hdr();
  bool useHdr = true;

  String get uid => widget.uid;

  @override
  void initState() {
    super.initState();
    var migrated = false;
    var raw = prefs.getString('qs_$uid');
    var h = prefs.getString('hdr_$uid');
    if (raw == null && prefs.getString('qs') != null) {
      raw = prefs.getString('qs');
      h ??= prefs.getString('hdr');
      prefs.remove('qs');
      prefs.remove('hdr');
      migrated = true;
    }
    if (raw != null) {
      qs = (jsonDecode(raw) as List).map((e) => Q.fromJson(e)).toList();
    }
    if (h != null) {
      hdr = Hdr.fromJson(jsonDecode(h));
    }
    useHdr = prefs.getBool('usehdr_$uid') ?? true;
    if (migrated) save();
  }

  void save() {
    prefs.setString('qs_$uid', jsonEncode(qs.map((e) => e.toJson()).toList()));
    prefs.setString('hdr_$uid', jsonEncode(hdr.toJson()));
    prefs.setBool('usehdr_$uid', useHdr);
  }

  double get total => qs.fold(0.0, (a, b) => a + b.points);

  void msg(String s) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  String baseName() {
    final p = [hdr['subject'], hdr['grade']]
        .where((e) => e.trim().isNotEmpty)
        .join(' ');
    final s = p
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), '_');
    return s.isEmpty ? 'azmoon' : s;
  }

  Future<void> edit([int? i]) async {
    final r = await Navigator.push<Q>(context,
        MaterialPageRoute(builder: (_) => Editor(q: i == null ? null : qs[i])));
    if (r == null) return;
    setState(() {
      if (i == null) {
        qs.add(r);
      } else {
        qs[i] = r;
      }
    });
    save();
  }

  Future<void> editHeader() async {
    final r = await Navigator.push<Hdr>(
        context, MaterialPageRoute(builder: (_) => HeaderEditor(h: hdr)));
    if (r != null) {
      setState(() => hdr = r);
      save();
    }
  }

  // ---------------- تبدیل فرمول به تصویر ----------------
  Future<Fx?> renderFx(String tex, {required bool textMode}) async {
    await ensureFxFont();
    final rtl = textMode ? lineRtl(tex) : hasPersian(tex);
    final key = GlobalKey();
    final entry = OverlayEntry(
      builder: (_) => Positioned(
        left: -5000,
        top: 0,
        child: UnconstrainedBox(
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: RepaintBoundary(
              key: key,
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(4),
                child: fxLineWidget(tex, textMode: textMode, maxW: 1040),
              ),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(entry);
    try {
      await WidgetsBinding.instance.endOfFrame;
      await Future.delayed(const Duration(milliseconds: 150));
      await WidgetsBinding.instance.endOfFrame;
      final ro = key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (ro == null) return null;
      final im = await ro.toImage(pixelRatio: 3);
      final bd = await im.toByteData(format: ui.ImageByteFormat.png);
      if (bd == null) return null;
      return Fx(bd.buffer.asUint8List(), im.width / 3, im.height / 3, rtl: rtl);
    } catch (_) {
      return null;
    } finally {
      entry.remove();
    }
  }

  Future<List<QFx>> renderAll() async {
    final out = <QFx>[];
    for (final q in qs) {
      final fl = <Fx>[];
      for (final line in q.formula.split('\n')) {
        final s = line.trim();
        if (s.isEmpty) continue;
        final f = await renderFx(s, textMode: false);
        if (f != null) fl.add(f);
      }
      final ls = <int, Fx>{};
      final tl = q.text.split('\n');
      for (var k = 0; k < tl.length; k++) {
        if (!hasMathMark(tl[k])) continue;
        final f = await renderFx(tl[k].trim(), textMode: true);
        if (f != null) ls[k] = f;
      }
      out.add(QFx(fl, ls));
    }
    return out;
  }

  Future<void> deliver(Uint8List bytes, String name, bool pdf) async {
    await showModalBottomSheet(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.download, color: kBlue),
            title: const Text('ذخیره در گوشی (دانلود مستقیم)'),
            onTap: () async {
              Navigator.pop(c);
              try {
                final p = await FlutterFileDialog.saveFile(
                    params: SaveFileDialogParams(data: bytes, fileName: name));
                if (p != null) msg('فایل ذخیره شد');
              } catch (e) {
                msg('خطا در ذخیره: $e');
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.share, color: kBlue),
            title: Text(pdf ? 'اشتراک‌گذاری / چاپ' : 'اشتراک‌گذاری'),
            onTap: () async {
              Navigator.pop(c);
              try {
                if (pdf) {
                  await Printing.sharePdf(bytes: bytes, filename: name);
                } else {
                  final dir = await getTemporaryDirectory();
                  final f = File('${dir.path}/$name');
                  await f.writeAsBytes(bytes, flush: true);
                  await Share.shareXFiles([
                    XFile(f.path,
                        mimeType:
                            'application/vnd.openxmlformats-officedocument.wordprocessingml.document')
                  ]);
                }
              } catch (e) {
                msg('خطا: $e');
              }
            },
          ),
        ]),
      ),
    );
  }

  String examId() => sha(jsonEncode(qs.map((e) => e.toJson()).toList()) +
      jsonEncode(hdr.toJson()) +
      useHdr.toString());

  Future<void> showPaywall() async {
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('پایان آزمون‌های رایگان'),
        content: Text(
            '${fa('$kFreeExams')} آزمون رایگان شما تمام شد. برای ساخت آزمون‌های نامحدود، نسخه‌ی کامل را از کافه‌بازار بخرید. خرید فقط یک بار انجام می‌شود.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c), child: const Text('بعداً')),
          TextButton(
            onPressed: () async {
              Navigator.pop(c);
              msg('در حال بررسی خرید...');
              final ok = await Lic.restore();
              if (!mounted) return;
              setState(() {});
              msg(ok
                  ? 'خرید شما بازیابی شد'
                  : 'خریدی برای این حساب کافه‌بازار پیدا نشد');
            },
            child: const Text('بازیابی خرید'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(c);
              final err = await Lic.buy();
              if (!mounted) return;
              setState(() {});
              msg(err ?? 'خرید موفق بود. نسخه‌ی کامل فعال شد.');
            },
            child: const Text('خرید نسخه‌ی کامل'),
          ),
        ],
      ),
    );
  }

  Future<void> exportPdf() async {
    final id = examId();
    if (qs.isNotEmpty && !Lic.canExport(id)) {
      await showPaywall();
      return;
    }
    final b = await buildPdf();
    if (b != null) {
      await Lic.register(id);
      if (mounted) setState(() {});
      await deliver(b, '${baseName()}.pdf', true);
    }
  }

  Future<void> exportDocx() async {
    final id = examId();
    if (qs.isNotEmpty && !Lic.canExport(id)) {
      await showPaywall();
      return;
    }
    final b = await buildDocx();
    if (b != null) {
      await Lic.register(id);
      if (mounted) setState(() {});
      await deliver(b, '${baseName()}.docx', false);
    }
  }

  // ---------------- ساخت PDF ----------------
  Future<Uint8List?> buildPdf() async {
    if (qs.isEmpty) {
      msg('ابتدا سؤال اضافه کنید');
      return null;
    }
    msg('در حال ساخت فایل...');
    final fxs = await renderAll();

    Future<pw.Font> lf(String a) async => pw.Font.ttf(await rootBundle.load(a));
    pw.Font fBase;
    try {
      fBase = await lf('assets/fonts/BNazanin.ttf');
    } catch (_) {
      fBase = await lf('assets/fonts/Vazir.ttf');
    }
    pw.Font fBold;
    try {
      fBold = await lf('assets/fonts/BNazaninBold.ttf');
    } catch (_) {
      fBold = fBase;
    }
    final doc =
        pw.Document(theme: pw.ThemeData.withFont(base: fBase, bold: fBold));

    pw.Widget t(String s,
            {double size = 12,
            pw.TextAlign a = pw.TextAlign.right,
            bool bold = false}) =>
        pw.Text(s,
            textDirection: pw.TextDirection.rtl,
            textAlign: a,
            style: pw.TextStyle(
                fontSize: size,
                fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal));

    pw.Widget qline(String s, {double size = 13}) {
      final rtl = isRtl(s);
      return pw.Align(
        alignment: rtl ? pw.Alignment.centerRight : pw.Alignment.centerLeft,
        child: pw.Text(s,
            textDirection: rtl ? pw.TextDirection.rtl : pw.TextDirection.ltr,
            textAlign: rtl ? pw.TextAlign.right : pw.TextAlign.left,
            style: pw.TextStyle(fontSize: size)),
      );
    }

    pw.Widget fit(String s,
            {double size = 12,
            bool b = false,
            pw.Alignment al = pw.Alignment.centerRight,
            pw.TextAlign ta = pw.TextAlign.right}) =>
        pw.FittedBox(
          fit: pw.BoxFit.scaleDown,
          alignment: al,
          child: pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 5),
            child: t(s, size: size, a: ta, bold: b),
          ),
        );

    // اعداد ردیف/بارم با رقم لاتین چاپ می‌شوند (فونت همان شکل فارسی را نشان می‌دهد)
    // چون رقم فارسی در متن LTR پکیج pdf گاهی اشتباه (مثلاً ۱ و ۲ به شکل ۳) رسم می‌شود
    pw.Widget numText(String s, {double size = 12, bool bold = false}) =>
        pw.Text(toEn(s).replaceAll('.', '/'),
            textDirection: pw.TextDirection.ltr,
            textAlign: pw.TextAlign.center,
            style: pw.TextStyle(
                fontSize: s.length > 4 ? size - 2 : size,
                fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal));

    final side = pw.BorderSide(width: 0.8);

    pw.Widget hc(String s, {bool last = false}) => pw.Container(
          height: 26,
          alignment: pw.Alignment.centerRight,
          padding: const pw.EdgeInsets.symmetric(horizontal: 6),
          decoration: last ? null : pw.BoxDecoration(border: pw.Border(bottom: side)),
          child: fit(s, size: 12, b: true),
        );

    pw.Widget col(List<String> rows) => pw.Column(
          mainAxisSize: pw.MainAxisSize.min,
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < rows.length; i++)
              hc(rows[i], last: i == rows.length - 1),
          ],
        );

    final mid = pw.Container(
      height: 130,
      padding: const pw.EdgeInsets.symmetric(horizontal: 4),
      decoration: pw.BoxDecoration(border: pw.Border(left: side, right: side)),
      child: pw.Column(
        mainAxisAlignment: pw.MainAxisAlignment.center,
        mainAxisSize: pw.MainAxisSize.min,
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          for (final l in hdr.midLines)
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
              child: fit(l,
                  size: 11,
                  b: true,
                  al: pw.Alignment.center,
                  ta: pw.TextAlign.center),
            ),
        ],
      ),
    );

    final headerW = pw.Container(
      decoration: pw.BoxDecoration(border: pw.Border.all(width: 1.5)),
      child: pw.Row(children: [
        pw.Expanded(flex: 3, child: col(hdr.leftRows)),
        pw.Expanded(flex: 4, child: mid),
        pw.Expanded(flex: 3, child: col(hdr.rightRows)),
      ]),
    );

    pw.Widget vcell(String s) => pw.Container(
          height: 28,
          alignment: pw.Alignment.center,
          child: pw.Transform.rotateBox(
            angle: math.pi / 2,
            child: t(s, size: 8, a: pw.TextAlign.center, bold: true),
          ),
        );

    final rows = <pw.TableRow>[
      pw.TableRow(repeat: true, children: [
        vcell('بارم'),
        pw.Container(
          height: 28,
          alignment: pw.Alignment.center,
          child: t('متن سوالات', size: 11, a: pw.TextAlign.center, bold: true),
        ),
        vcell('ردیف'),
      ]),
    ];

    for (var i = 0; i < qs.length; i++) {
      final q = qs[i];
      final content = <pw.Widget>[];
      final rtlQ = q.text.trim().isEmpty ? true : isRtl(q.text);
      final lab = rtlQ ? kLabels : kLatin;

      final qLines = q.text.split('\n');
      for (var li = 0; li < qLines.length; li++) {
        final l = qLines[li];
        if (l.trim().isEmpty) continue;
        final fx = fxs[i].lines[li];
        if (fx != null) {
          content.add(pw.SizedBox(height: 2));
          content.add(pw.Align(
            alignment:
                fx.rtl ? pw.Alignment.centerRight : pw.Alignment.centerLeft,
            child: pw.Image(pw.MemoryImage(fx.bytes),
                width: fx.w * kFxScale,
                height: fx.h * kFxScale,
                fit: pw.BoxFit.fill),
          ));
          content.add(pw.SizedBox(height: 2));
        } else {
          content.add(qline(l, size: 13));
        }
      }
      for (final f in fxs[i].formulas) {
        content.add(pw.SizedBox(height: 3));
        content.add(pw.Align(
          alignment: f.rtl ? pw.Alignment.centerRight : pw.Alignment.centerLeft,
          child: pw.Padding(
            padding: pw.EdgeInsets.only(left: f.rtl ? 0 : 8),
            child: pw.Image(pw.MemoryImage(f.bytes),
                width: f.w * kFxScale,
                height: f.h * kFxScale,
                fit: pw.BoxFit.fill),
          ),
        ));
      }

      var hasImg = false;
      var imgOnly = false;
      if (q.image != null && File(q.image!).existsSync()) {
        final sz = await imgSize(q.image!);
        if (sz != null) {
          hasImg = true;
          imgOnly = q.text.trim().isEmpty && !q.imgManual;
          double w, h;
          pw.Alignment al;
          if (imgOnly) {
            // تصویر به جای صورت سؤال: تمام عرض سلول، چسبیده به راست
            w = 462;
            h = w * sz.height / sz.width;
            if (h > 640) {
              h = 640;
              w = h * sz.width / sz.height;
            }
            al = pw.Alignment.centerRight;
          } else {
            final bw = q.imgW * kCm;
            final bh = q.imgH * kCm;
            final s = math.min(bw / sz.width, bh / sz.height);
            w = sz.width * s;
            h = sz.height * s;
            al = q.imgAlign == 'l'
                ? pw.Alignment.centerLeft
                : (q.imgAlign == 'r'
                    ? pw.Alignment.centerRight
                    : pw.Alignment.center);
            content.add(pw.SizedBox(height: 4));
          }
          content.add(pw.Align(
            alignment: al,
            child: pw.Image(pw.MemoryImage(File(q.image!).readAsBytesSync()),
                width: w, height: h, fit: pw.BoxFit.fill),
          ));
        }
      }

      if (q.type == 'mc' && q.options.any((o) => o.isNotEmpty)) {
        content.add(pw.SizedBox(height: 4));
        final short = q.options.every((o) => o.length <= 14);
        if (short) {
          content.add(pw.Row(children: [
            for (var k = 3; k >= 0; k--)
              pw.Expanded(child: qline('${lab[k]}) ${q.options[k]}', size: 12)),
          ]));
        } else {
          for (var k = 0; k < 4; k++) {
            content.add(qline('${lab[k]}) ${q.options[k]}', size: 12));
          }
        }
      } else if (q.type == 'tf') {
        content.add(pw.SizedBox(height: 4));
        content.add(qline(
            rtlQ
                ? '(    ) صحیح          (    ) غلط'
                : '(    ) True          (    ) False',
            size: 12));
      } else if (q.type == 'desc') {
        // فضای پاسخ: به تعداد خط مشخص‌شده
        final n = math.min(30, math.max(0, q.lines));
        if (n > 0) {
          content.add(pw.SizedBox(height: 4));
          content.add(pw.SizedBox(height: 24.0 * n));
        }
      }

      rows.add(pw.TableRow(children: [
        pw.Container(
          alignment: pw.Alignment.center,
          padding: const pw.EdgeInsets.all(2),
          child: numText(num2(q.points)),
        ),
        pw.Padding(
          padding: imgOnly
              ? const pw.EdgeInsets.fromLTRB(4, 4, 6, 4)
              : const pw.EdgeInsets.all(8),
          child: pw.Column(
            mainAxisSize: pw.MainAxisSize.min,
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: content.isEmpty ? [pw.SizedBox(height: 10)] : content,
          ),
        ),
        pw.Container(
          alignment: pw.Alignment.center,
          padding: const pw.EdgeInsets.all(2),
          child: numText(fa('${i + 1}')),
        ),
      ]));
      if (hasImg) {}
    }

    // ردیف پایانی: «موفق باشید» + جمع بارم
    rows.add(pw.TableRow(children: [
      pw.Container(
        height: 30,
        alignment: pw.Alignment.center,
        padding: const pw.EdgeInsets.all(2),
        child: numText(num2(total), bold: true),
      ),
      pw.Container(
        height: 30,
        alignment: pw.Alignment.center,
        child: t('موفق باشید', size: 13, a: pw.TextAlign.center, bold: true),
      ),
      pw.Container(height: 30),
    ]));

    final table = pw.Table(
      border: pw.TableBorder.all(width: 1),
      columnWidths: {
        0: const pw.FixedColumnWidth(26),
        1: const pw.FlexColumnWidth(),
        2: const pw.FixedColumnWidth(28),
      },
      defaultVerticalAlignment: pw.TableCellVerticalAlignment.full,
      children: rows,
    );

    final logoBytes = await loadLogo();
    final logoImg = logoBytes == null ? null : pw.MemoryImage(logoBytes);
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(28),
      footer: (c) => pw.Container(
        margin: const pw.EdgeInsets.only(top: 6),
        padding: const pw.EdgeInsets.only(top: 3),
        decoration: pw.BoxDecoration(
            border: pw.Border(top: pw.BorderSide(width: 0.5))),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text('${c.pageNumber} / ${c.pagesCount}',
                textDirection: pw.TextDirection.ltr,
                style: pw.TextStyle(fontSize: 9)),
            pw.Row(mainAxisSize: pw.MainAxisSize.min, children: [
              if (logoImg != null) ...[
                pw.Image(logoImg, width: 14, height: 14),
                pw.SizedBox(width: 4),
              ],
              t(kSignature, size: 10, a: pw.TextAlign.center, bold: true),
            ]),
            pw.SizedBox(width: 30),
          ],
        ),
      ),
      build: (c) => [if (useHdr) headerW, table],
    ));
    return Uint8List.fromList(await doc.save());
  }

  // ---------------- ساخت Word ----------------
  Future<Uint8List?> buildDocx() async {
    if (qs.isEmpty) {
      msg('ابتدا سؤال اضافه کنید');
      return null;
    }
    msg('در حال ساخت فایل...');
    final fxs = await renderAll();
    final media = <String, List<int>>{};
    final rels = StringBuffer();
    var imgId = 0;

    String addPic(List<int> bytes, int cx, int cy, String jc, {int ind = 0}) {
      imgId++;
      final ext = (bytes.length > 1 && bytes[0] == 0x89) ? 'png' : 'jpeg';
      final name = 'image$imgId.$ext';
      media[name] = bytes;
      rels.write(
          '<Relationship Id="rIdImg$imgId" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/$name"/>');
      return '<w:p><w:pPr><w:spacing w:before="60" w:after="60"/>'
          '${ind > 0 ? '<w:ind w:left="$ind"/>' : ''}<w:jc w:val="$jc"/></w:pPr>'
          '<w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">'
          '<wp:extent cx="$cx" cy="$cy"/><wp:docPr id="$imgId" name="Picture $imgId"/>'
          '<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>'
          '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
          '<pic:pic><pic:nvPicPr><pic:cNvPr id="$imgId" name="$name"/><pic:cNvPicPr/></pic:nvPicPr>'
          '<pic:blipFill><a:blip r:embed="rIdImg$imgId"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
          '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="$cx" cy="$cy"/></a:xfrm>'
          '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>'
          '</a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>';
    }

    final body = StringBuffer();

    if (useHdr) {
      final midParas = hdr.midLines
          .map((l) => pp(rp(l, sz: fitSz(l, 18, 40), b: true), center: true))
          .join();
      final right = hdr.rightRows;
      final left = hdr.leftRows;
      body.write('<w:tbl>${tblPr(8)}<w:tblGrid>'
          '<w:gridCol w:w="3300"/><w:gridCol w:w="4100"/><w:gridCol w:w="3300"/></w:tblGrid>');
      for (var i = 0; i < 5; i++) {
        final midCell = i == 0
            ? tcX(midParas, 4100, vm: '<w:vMerge w:val="restart"/>', va: 'center')
            : tcX('<w:p/>', 4100, vm: '<w:vMerge/>');
        body.write(trX(
          tcX(pp(rp(right[i], sz: fitSz(right[i], 20, 26), b: true)), 3300,
                  va: 'center') +
              midCell +
              tcX(pp(rp(left[i], sz: fitSz(left[i], 20, 26), b: true)), 3300,
                  va: 'center'),
          h: 420,
        ));
      }
      body.write('</w:tbl>');
      body.write(
          '<w:p><w:pPr><w:spacing w:before="0" w:after="0" w:line="20" w:lineRule="exact"/></w:pPr></w:p>');
    }

    body.write('<w:tbl>${tblPr(8)}<w:tblGrid>'
        '<w:gridCol w:w="560"/><w:gridCol w:w="9620"/><w:gridCol w:w="520"/></w:tblGrid>');
    body.write(trX(
        tcX(pp(rp('ردیف', sz: 14, b: true), center: true), 560,
                td: true, va: 'center') +
            tcX(pp(rp('متن سوالات', sz: 20, b: true), center: true), 9620,
                va: 'center') +
            tcX(pp(rp('بارم', sz: 14, b: true), center: true), 520,
                td: true, va: 'center'),
        h: 520));

    for (var i = 0; i < qs.length; i++) {
      final q = qs[i];
      final c = StringBuffer();
      final rtlQ = q.text.trim().isEmpty ? true : isRtl(q.text);
      final lab = rtlQ ? kLabels : kLatin;

      final qLines = q.text.split('\n');
      for (var li = 0; li < qLines.length; li++) {
        final l = qLines[li];
        if (l.trim().isEmpty) continue;
        final fx = fxs[i].lines[li];
        if (fx != null) {
          c.write(addPic(fx.bytes, (fx.w * kFxScale * 12700).round(),
              (fx.h * kFxScale * 12700).round(), fx.rtl ? 'right' : 'left'));
        } else {
          final r = isRtl(l);
          c.write(pp(rp(l, sz: 24, rtl: r), rtl: r));
        }
      }
      for (final f in fxs[i].formulas) {
        c.write(addPic(f.bytes, (f.w * kFxScale * 12700).round(),
            (f.h * kFxScale * 12700).round(), f.rtl ? 'right' : 'left',
            ind: f.rtl ? 0 : 160));
      }
      if (q.image != null && File(q.image!).existsSync()) {
        final sz = await imgSize(q.image!);
        if (sz != null) {
          final imgOnly = q.text.trim().isEmpty && !q.imgManual;
          double cx, cy;
          String jc;
          if (imgOnly) {
            // تصویر به جای صورت سؤال: تمام عرض سلول، چسبیده به راست
            cx = 9000 * 635.0;
            cy = cx * sz.height / sz.width;
            const maxH = 7920000.0; // حدود ۲۲ سانتی‌متر
            if (cy > maxH) {
              cy = maxH;
              cx = cy * sz.width / sz.height;
            }
            jc = 'right';
          } else {
            final bw = q.imgW * 360000;
            final bh = q.imgH * 360000;
            final s = math.min(bw / sz.width, bh / sz.height);
            cx = sz.width * s;
            cy = sz.height * s;
            jc = q.imgAlign == 'l' ? 'left' : (q.imgAlign == 'r' ? 'right' : 'center');
          }
          c.write(addPic(
              File(q.image!).readAsBytesSync(), cx.round(), cy.round(), jc));
        }
      }
      if (q.type == 'mc' && q.options.any((o) => o.isNotEmpty)) {
        for (var k = 0; k < 4; k++) {
          final line = '${lab[k]}) ${q.options[k]}';
          final r = isRtl(line);
          c.write(pp(rp(line, sz: 22, rtl: r), rtl: r));
        }
      } else if (q.type == 'tf') {
        c.write(pp(
            rp(
                rtlQ
                    ? '(     ) صحیح          (     ) غلط'
                    : '(     ) True          (     ) False',
                sz: 22,
                rtl: rtlQ),
            rtl: rtlQ));
      } else if (q.type == 'desc') {
        final n = math.min(30, math.max(0, q.lines));
        for (var k = 0; k < n; k++) {
          c.write(
              '<w:p><w:pPr><w:spacing w:before="0" w:after="0" w:line="480" w:lineRule="exact"/></w:pPr></w:p>');
        }
      }
      if (c.isEmpty) c.write('<w:p/>');
      body.write(trX(
        tcX(pp(rp(fa('${i + 1}'), sz: 22, rtl: false), center: true, rtl: false),
                560,
                va: 'center') +
            tcX(c.toString(), 9620) +
            tcX(pp(rp(num2(q.points), sz: 22, rtl: false), center: true, rtl: false),
                520,
                va: 'center'),
        h: 600,
      ));
    }
    // ردیف پایانی: «موفق باشید» + جمع بارم
    body.write(trX(
      tcX('<w:p/>', 560, va: 'center') +
          tcX(pp(rp('موفق باشید', sz: 24, b: true), center: true), 9620,
              va: 'center') +
          tcX(pp(rp(num2(total), sz: 22, b: true, rtl: false),
                  center: true, rtl: false),
              520,
              va: 'center'),
      h: 560,
    ));
    body.write('</w:tbl><w:p/>');

    const ns =
        'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
        'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" '
        'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
        'xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"';
    const xmlHead = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>';

    final documentXml = '$xmlHead<w:document $ns><w:body>$body'
        '<w:sectPr><w:footerReference w:type="default" r:id="rIdFooter1"/>'
        '<w:pgSz w:w="11906" w:h="16838"/>'
        '<w:pgMar w:top="567" w:right="567" w:bottom="567" w:left="567" w:header="400" w:footer="400" w:gutter="0"/>'
        '<w:bidi/></w:sectPr></w:body></w:document>';

    const contentTypes =
        '$xmlHead<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Default Extension="png" ContentType="image/png"/>'
        '<Default Extension="jpeg" ContentType="image/jpeg"/>'
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        '<Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>'
        '</Types>';

    const rootRels =
        '$xmlHead<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
        '</Relationships>';

    final docRels =
        '$xmlHead<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">$rels'
        '<Relationship Id="rIdFooter1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/>'
        '</Relationships>';
    final logoBytes = await loadLogo();
    final logoRun = logoBytes == null
        ? ''
        : '<w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">'
            '<wp:extent cx="203200" cy="203200"/><wp:docPr id="9999" name="Logo"/>'
            '<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>'
            '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
            '<pic:pic><pic:nvPicPr><pic:cNvPr id="9999" name="logo.png"/><pic:cNvPicPr/></pic:nvPicPr>'
            '<pic:blipFill><a:blip r:embed="rIdLogo"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
            '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="203200" cy="203200"/></a:xfrm>'
            '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>'
            '</a:graphicData></a:graphic></wp:inline></w:drawing></w:r>'
            '<w:r><w:t xml:space="preserve">  </w:t></w:r>';
    final footerXml =
        '$xmlHead<w:ftr $ns><w:p><w:pPr><w:bidi/><w:jc w:val="center"/></w:pPr>'
        '$logoRun${rp(kSignature, sz: 18, b: true)}</w:p></w:ftr>';
    final footerRels =
        '$xmlHead<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '${logoBytes == null ? '' : '<Relationship Id="rIdLogo" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/logo.png"/>'}'
        '</Relationships>';

    final arc = Archive();
    void add(String n, List<int> b) => arc.addFile(ArchiveFile(n, b.length, b));
    add('[Content_Types].xml', utf8.encode(contentTypes));
    add('_rels/.rels', utf8.encode(rootRels));
    add('word/document.xml', utf8.encode(documentXml));
    add('word/_rels/document.xml.rels', utf8.encode(docRels));
    add('word/footer1.xml', utf8.encode(footerXml));
    add('word/_rels/footer1.xml.rels', utf8.encode(footerRels));
    if (logoBytes != null) add('word/media/logo.png', logoBytes);
    media.forEach((k, v) => add('word/media/$k', v));

    final z = ZipEncoder().encode(arc) as List<int>;
    return Uint8List.fromList(z);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: bar('آزمون بساز', actions: [
        actBtn(Icons.description, 'ورد', exportDocx),
        actBtn(Icons.picture_as_pdf, 'پی‌دی‌اف', exportPdf),
        const SizedBox(width: 8),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: kBlue,
        foregroundColor: Colors.white,
        onPressed: () => edit(),
        icon: const Icon(Icons.add),
        label: const Text('افزودن سؤال'),
      ),
      body: Column(children: [
        // انتخاب سربرگ + کلید روشن/خاموش
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Row(children: [
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: useHdr ? editHeader : null,
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                        colors: useHdr
                            ? [const Color(0xFFFF9800), const Color(0xFFEF6C00)]
                            : [Colors.grey.shade400, Colors.grey.shade500]),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(children: [
                    const Icon(Icons.badge, color: Colors.white),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('انتخاب سربرگ',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16)),
                            Text(
                                hdr['school'].isEmpty
                                    ? 'برای ویرایش مشخصات سربرگ بزنید'
                                    : '${hdr['school']}  ${hdr['subject']} ${hdr['grade']}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 12)),
                          ]),
                    ),
                    const Icon(Icons.edit, color: Colors.white),
                  ]),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Switch(
              value: useHdr,
              onChanged: (v) {
                setState(() => useHdr = v);
                save();
              },
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(
              'تعداد سؤال: ${fa('${qs.length}')}   |   جمع بارم: ${num2(total)}${Lic.premium ? '' : '   |   آزمون رایگان باقی‌مانده: ${fa('${Lic.left}')}'}',
              style: const TextStyle(color: kBlue, fontWeight: FontWeight.bold)),
        ),
        Expanded(
          child: qs.isEmpty
              ? const Center(child: Text('هنوز سؤالی ندارید'))
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 90),
                  itemCount: qs.length,
                  itemBuilder: (c, i) {
                    final q = qs[i];
                    return Card(
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                      child: ListTile(
                        leading: CircleAvatar(
                            backgroundColor: kBlue,
                            foregroundColor: Colors.white,
                            child: Text(fa('${i + 1}'))),
                        title: Text(
                            q.text.isEmpty
                                ? (q.formula.isNotEmpty ? 'سؤال فرمولی' : 'سؤال تصویری')
                                : q.text,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                            '${typeName(q.type)} - ${num2(q.points)} نمره${q.image != null ? ' - دارای تصویر' : ''}${q.formula.isNotEmpty ? ' - دارای فرمول' : ''}'),
                        onTap: () => edit(i),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete, color: Colors.redAccent),
                          onPressed: () {
                            setState(() => qs.removeAt(i));
                            save();
                          },
                        ),
                      ),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}

class HeaderEditor extends StatefulWidget {
  final Hdr h;
  const HeaderEditor({super.key, required this.h});
  @override
  State<HeaderEditor> createState() => _HeaderEditorState();
}

class _HeaderEditorState extends State<HeaderEditor> {
  late final Map<String, TextEditingController> c;

  @override
  void initState() {
    super.initState();
    c = {
      for (final k in hdrLabels.keys) k: TextEditingController(text: widget.h[k])
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: bar('سربرگ آزمون'),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        for (final k in hdrLabels.keys) field(c[k]!, hdrLabels[k]!),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: kBlue, padding: const EdgeInsets.all(16)),
          onPressed: () {
            Navigator.pop(
                context,
                Hdr({for (final k in hdrLabels.keys) k: c[k]!.text.trim()}));
          },
          child: const Text('ذخیره سربرگ', style: TextStyle(fontSize: 16)),
        ),
      ]),
    );
  }
}

// ---------------- ویرایش سؤال ----------------
class Editor extends StatefulWidget {
  final Q? q;
  const Editor({super.key, this.q});
  @override
  State<Editor> createState() => _EditorState();
}

class _EditorState extends State<Editor> {
  String type = 'desc'; // پیش‌فرض: تشریحی
  String? image;
  double imgW = 10, imgH = 6;
  String imgAlign = 'c';
  bool manual = false;
  bool showFx = false;
  final text = TextEditingController();
  final formula = TextEditingController();
  final pts = TextEditingController(text: '1');
  final lines = TextEditingController();
  final opts = List.generate(4, (_) => TextEditingController());

  static const syms = <(String, String, int)>[
    ('کسر  a⁄b', r'\frac{}{}', 3),
    ('توان  xⁿ', r'^{}', 1),
    ('اندیس  xₙ', r'_{}', 1),
    ('ریشه  √', r'\sqrt{}', 1),
    ('π', r'\pi ', 0),
    ('≤', r'\leq ', 0),
    ('≥', r'\geq ', 0),
    ('≠', r'\neq ', 0),
    ('×', r'\times ', 0),
    ('÷', r'\div ', 0),
    ('±', r'\pm ', 0),
    ('∞', r'\infty ', 0),
    ('Σ', r'\sum ', 0),
    ('∫', r'\int ', 0),
    ('°', r'^\circ ', 0),
    ('→', r'\rightarrow ', 0),
    ('Δ', r'\Delta ', 0),
    ('α', r'\alpha ', 0),
    ('β', r'\beta ', 0),
    ('θ', r'\theta ', 0),
    ('حد  lim', r'\lim_{x \to }', 1),
    ('log', r'\log_{}', 1),
    ('sin', r'\sin ', 0),
    ('cos', r'\cos ', 0),
    ('tan', r'\tan ', 0),
    ('∈', r'\in ', 0),
    ('∪', r'\cup ', 0),
    ('∩', r'\cap ', 0),
    ('⊂', r'\subset ', 0),
    ('⇒', r'\Rightarrow ', 0),
    ('⇔', r'\Leftrightarrow ', 0),
  ];

  @override
  void initState() {
    super.initState();
    ensureFxFont().then((_) {
      if (mounted) setState(() {});
    });
    final q = widget.q;
    if (q != null) {
      type = q.type;
      text.text = q.text;
      formula.text = q.formula;
      showFx = q.formula.isNotEmpty;
      pts.text = q.points.toString();
      image = q.image;
      imgW = q.imgW.clamp(1.0, 16.0).toDouble();
      imgH = q.imgH.clamp(1.0, 15.0).toDouble();
      imgAlign = q.imgAlign;
      manual = q.imgManual;
      lines.text = q.lines > 0 ? '${q.lines}' : '';
      for (var i = 0; i < 4; i++) {
        opts[i].text = q.options[i];
      }
    }
  }

  void ins(String s, int back) {
    final v = formula.value;
    final sel = v.selection;
    final st = sel.isValid ? sel.start : v.text.length;
    final en = sel.isValid ? sel.end : v.text.length;
    final t = v.text.replaceRange(st, en, s);
    formula.value = TextEditingValue(
      text: t,
      selection: TextSelection.collapsed(offset: st + s.length - back),
    );
    setState(() {});
  }

  // درج فرمول در متن سؤال (محل مکان‌نما) و خالی کردن کادر فرمول
  void insertFormula() {
    final f = formula.text
        .split('\n')
        .map((e) => e.replaceAll(r'$', '').trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (f.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('ابتدا فرمول را بنویسید')));
      return;
    }
    final ins = f.map((e) => '\$$e\$').join(' ');
    final v = text.value;
    final sel = v.selection;
    final st = sel.isValid ? sel.start : v.text.length;
    final en = sel.isValid ? sel.end : v.text.length;
    final before = v.text.substring(0, st);
    final after = v.text.substring(en);
    final pre = (before.isEmpty || before.endsWith(' ') || before.endsWith('\n'))
        ? ''
        : ' ';
    final post =
        (after.isEmpty || after.startsWith(' ') || after.startsWith('\n'))
            ? ''
            : ' ';
    final mid = '$pre$ins$post';
    text.value = TextEditingValue(
      text: '$before$mid$after',
      selection: TextSelection.collapsed(offset: before.length + mid.length),
    );
    formula.clear();
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('فرمول در متن سؤال درج شد. فرمول بعدی را بنویسید.')));
  }

  Future<void> startManual() async {
    var w = 16.0;
    var h = 10.0;
    final sz = image == null ? null : await imgSize(image!);
    if (sz != null) {
      h = w * sz.height / sz.width;
      if (h > 15) {
        h = 15;
        w = h * sz.width / sz.height;
      }
    }
    setState(() {
      manual = true;
      imgW = double.parse(w.clamp(1.0, 16.0).toStringAsFixed(1));
      imgH = double.parse(h.clamp(1.0, 15.0).toStringAsFixed(1));
      imgAlign = 'r';
    });
  }

  Future<void> choose() async {
    final p = await pickImage();
    if (p == null) return;
    var w = 10.0;
    var h = 6.0;
    final sz = await imgSize(p);
    if (sz != null) {
      h = w * sz.height / sz.width;
      if (h > 12) {
        h = 12;
        w = h * sz.width / sz.height;
      }
    }
    setState(() {
      image = p;
      imgW = double.parse(w.clamp(1.0, 16.0).toStringAsFixed(1));
      imgH = double.parse(h.clamp(1.0, 15.0).toStringAsFixed(1));
    });
  }

  @override
  Widget build(BuildContext context) {
    final fLines =
        formula.text.split('\n').where((e) => e.trim().isNotEmpty).toList();
    final imgOnly = text.text.trim().isEmpty && image != null && !manual;
    return Scaffold(
      appBar: bar('سؤال'),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'desc', label: Text('تشریحی')),
            ButtonSegment(value: 'tf', label: Text('صحیح/غلط')),
            ButtonSegment(value: 'mc', label: Text('چهارگزینه‌ای')),
          ],
          selected: {type},
          onSelectionChanged: (s) => setState(() => type = s.first),
        ),
        const SizedBox(height: 16),
        field(text, 'متن سؤال (اگر صورت سؤال در تصویر است، خالی بگذارید)',
            lines: 2, onChanged: (_) => setState(() {})),
        if (hasMathMark(text.text))
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: kBlue.withOpacity(0.3))),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('پیش‌نمایش سؤال با فرمول‌ها',
                    style: TextStyle(fontSize: 11, color: Colors.black54)),
                const SizedBox(height: 6),
                for (final l in text.text.split('\n'))
                  if (l.trim().isNotEmpty)
                    Align(
                      alignment: lineRtl(l)
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: fxLineWidget(l.trim(),
                          textMode: true,
                          fs: 18,
                          maxW: MediaQuery.of(context).size.width - 70),
                    ),
              ],
            ),
          ),

        // ---- دکمه فرمول ریاضی ----
        OutlinedButton.icon(
          onPressed: () => setState(() => showFx = !showFx),
          icon: const Icon(Icons.functions),
          label: Text(showFx ? 'بستن فرمول ریاضی' : 'فرمول ریاضی'),
        ),
        if (showFx) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 0, children: [
            for (final s in syms)
              ActionChip(
                label: Text(s.$1, style: const TextStyle(fontSize: 15)),
                onPressed: () => ins(s.$2, s.$3),
              ),
          ]),
          const SizedBox(height: 6),
          TextField(
            controller: formula,
            textDirection: hasPersian(formula.text)
                ? TextDirection.rtl
                : TextDirection.ltr,
            textAlign:
                hasPersian(formula.text) ? TextAlign.right : TextAlign.left,
            minLines: 2,
            maxLines: 5,
            onChanged: (_) => setState(() {}),
            style: hasPersian(formula.text)
                ? null
                : const TextStyle(fontFamily: 'monospace'),
            decoration: InputDecoration(
              filled: true,
              fillColor: Colors.white,
              labelText:
                  'فرمول (کلمات فارسی را بیرون از { } بنویسید؛ هر خط یک فرمول)',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
          for (final l in fLines)
            Container(
              margin: const EdgeInsets.only(top: 6),
              padding: const EdgeInsets.all(8),
              width: double.infinity,
              decoration: BoxDecoration(
                  color: Colors.white, borderRadius: BorderRadius.circular(12)),
              child: Align(
                alignment: hasPersian(l)
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: fxLineWidget(l.trim(),
                      textMode: false,
                      fs: 22,
                      maxW: MediaQuery.of(context).size.width - 70),
                ),
              ),
            ),
          const SizedBox(height: 8),
          FilledButton.icon(
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF2E7D32),
                padding: const EdgeInsets.all(12)),
            onPressed: insertFormula,
            icon: const Icon(Icons.add_circle),
            label: const Text('درج فرمول در متن سؤال'),
          ),
        ],
        const SizedBox(height: 16),

        // ---- تصویر ----
        OutlinedButton.icon(
          onPressed: choose,
          icon: const Icon(Icons.image),
          label: Text(image == null ? 'درج تصویر' : 'تغییر تصویر'),
        ),
        if (image != null) ...[
          const SizedBox(height: 8),
          if (imgOnly) ...[
            Container(
              padding: const EdgeInsets.all(10),
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                  color: const Color(0xFFE3F2FD),
                  borderRadius: BorderRadius.circular(12)),
              child: const Text(
                  'چون متن سؤال خالی است، تصویر به‌عنوان صورت سؤال و با عرض کامل سلول چاپ می‌شود.'),
            ),
            Image.file(File(image!), fit: BoxFit.contain),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: startManual,
              icon: const Icon(Icons.aspect_ratio),
              label: const Text('تغییر اندازه‌ی تصویر'),
            ),
          ] else ...[
            if (text.text.trim().isEmpty)
              OutlinedButton.icon(
                onPressed: () => setState(() => manual = false),
                icon: const Icon(Icons.fit_screen),
                label: const Text('برگشت به عرض کامل'),
              ),
            Align(
              alignment: imgAlign == 'l'
                  ? Alignment.centerLeft
                  : (imgAlign == 'r' ? Alignment.centerRight : Alignment.center),
              child: SizedBox(
                width: imgW * 20,
                height: imgH * 20,
                child: Image.file(File(image!), fit: BoxFit.contain),
              ),
            ),
            Text('عرض: ${num2(imgW)} سانتی‌متر'),
            Slider(
              value: imgW,
              min: 1,
              max: 16,
              divisions: 150,
              onChanged: (v) =>
                  setState(() => imgW = double.parse(v.toStringAsFixed(1))),
            ),
            Text('ارتفاع: ${num2(imgH)} سانتی‌متر'),
            Slider(
              value: imgH,
              min: 1,
              max: 15,
              divisions: 140,
              onChanged: (v) =>
                  setState(() => imgH = double.parse(v.toStringAsFixed(1))),
            ),
            const Text('جایگاه تصویر'),
            const SizedBox(height: 4),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'l', label: Text('چپ')),
                ButtonSegment(value: 'c', label: Text('وسط')),
                ButtonSegment(value: 'r', label: Text('راست')),
              ],
              selected: {imgAlign},
              onSelectionChanged: (s) => setState(() => imgAlign = s.first),
            ),
          ],
          TextButton.icon(
            onPressed: () => setState(() => image = null),
            icon: const Icon(Icons.delete, color: Colors.redAccent),
            label: const Text('حذف تصویر'),
          ),
        ],
        const SizedBox(height: 12),
        if (type == 'mc')
          for (var i = 0; i < 4; i++) field(opts[i], 'گزینه ${kLabels[i]}'),
        if (type == 'desc')
          field(lines, 'تعداد خط پاسخ (خالی یا ۰ = بدون فضای پاسخ)',
              kb: TextInputType.number),
        field(pts, 'بارم (نمره) - مثال: ۲/۵',
            kb: const TextInputType.numberWithOptions(decimal: true)),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: kBlue, padding: const EdgeInsets.all(16)),
          onPressed: () {
            if (text.text.trim().isEmpty &&
                image == null &&
                formula.text.trim().isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('متن، تصویر یا فرمول سؤال را وارد کنید')));
              return;
            }
            Navigator.pop(
                context,
                Q(
                  type: type,
                  text: text.text.trim(),
                  formula: formula.text.trim(),
                  options: opts.map((e) => e.text.trim()).toList(),
                  points: double.tryParse(toEn(pts.text.trim())) ?? 1,
                  image: image,
                  imgW: imgW,
                  imgH: imgH,
                  imgAlign: imgAlign,
                  imgManual: manual,
                  lines: math.min(
                      30, math.max(0, int.tryParse(toEn(lines.text.trim())) ?? 0)),
                ));
          },
          child: const Text('ثبت سؤال', style: TextStyle(fontSize: 16)),
        ),
      ]),
    );
  }
}
