import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:archive/archive.dart' show Archive, ArchiveFile, ZipEncoder;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const App());

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
String num2(double p) =>
    fa(p % 1 == 0 ? p.toInt().toString() : p.toString()).replaceAll('.', '/');

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

// جهت متن: اگر اولین حرف مهم فارسی/عربی بود راست‌به‌چپ، اگر انگلیسی بود چپ‌به‌راست
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
    // webp, gif, bmp, ... را به PNG تبدیل می‌کنیم
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

// تصویر فرمول
class Fx {
  final Uint8List bytes;
  final double w, h; // اندازه منطقی (فونت ۳۰)
  Fx(this.bytes, this.w, this.h);
}

const kFxScale = 13 / 30; // فرمول با فونت حدود ۱۳ پوینت چاپ می‌شود

// ---------------- مدل سؤال ----------------
class Q {
  String type; // mc, tf, desc
  String text;
  String formula;
  List<String> options;
  double points;
  String? image;
  double imgW; // سانتی‌متر
  double imgH; // سانتی‌متر
  String imgAlign; // l, c, r
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

  // ستون راست سربرگ: مشخصات دانش‌آموز
  List<String> get rightRows => [
        'نام و نام خانوادگی: ................',
        'نام پدر: ................',
        'شماره دانش‌آموزی: ................',
        'نام کلاس: ................',
        'پایه: ${this['grade']}      نام دبیر: ${this['teacher']}',
      ];

  // ستون چپ سربرگ: مشخصات امتحان
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

// اگر متن طولانی بود، اندازه فونت کم می‌شود
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
        {int lines = 1, TextInputType? kb}) =>
    Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        minLines: lines,
        maxLines: lines + 3,
        keyboardType: kb,
        decoration: InputDecoration(
          filled: true,
          fillColor: Colors.white,
          labelText: label,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
    );

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
      home: const Home(),
    );
  }
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  List<Q> qs = [];
  Hdr hdr = Hdr();
  SharedPreferences? sp;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    sp = await SharedPreferences.getInstance();
    final raw = sp!.getString('qs');
    if (raw != null) {
      qs = (jsonDecode(raw) as List).map((e) => Q.fromJson(e)).toList();
    }
    final h = sp!.getString('hdr');
    if (h != null) {
      hdr = Hdr.fromJson(jsonDecode(h));
    }
    setState(() {});
  }

  void save() {
    sp?.setString('qs', jsonEncode(qs.map((e) => e.toJson()).toList()));
    sp?.setString('hdr', jsonEncode(hdr.toJson()));
  }

  double get total => qs.fold(0.0, (a, b) => a + b.points);

  void msg(String s) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  // نام فایل: درس + پایه
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
  Future<Fx?> renderTex(String tex) async {
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
                child: Math.tex(tex,
                    textStyle:
                        const TextStyle(fontSize: 30, color: Colors.black)),
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
      return Fx(bd.buffer.asUint8List(), im.width / 3, im.height / 3);
    } catch (_) {
      return null;
    } finally {
      entry.remove();
    }
  }

  Future<List<List<Fx>>> renderAll() async {
    final out = <List<Fx>>[];
    for (final q in qs) {
      final l = <Fx>[];
      for (final line in q.formula.split('\n')) {
        final s = line.trim();
        if (s.isEmpty) continue;
        final f = await renderTex(s);
        if (f != null) l.add(f);
      }
      out.add(l);
    }
    return out;
  }

  // ---------------- تحویل فایل: ذخیره مستقیم یا اشتراک‌گذاری ----------------
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

  Future<void> exportPdf() async {
    final b = await buildPdf();
    if (b != null) await deliver(b, '${baseName()}.pdf', true);
  }

  Future<void> exportDocx() async {
    final b = await buildDocx();
    if (b != null) await deliver(b, '${baseName()}.docx', false);
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

    // خط سؤال: فارسی راست‌چین، انگلیسی چپ‌چین
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

    // متنی که اگر از سلول بزرگ‌تر شد، خودکار کوچک می‌شود
    pw.Widget fit(String s,
            {double size = 12,
            bool b = false,
            pw.Alignment al = pw.Alignment.centerRight,
            pw.TextAlign ta = pw.TextAlign.right}) =>
        pw.FittedBox(
          fit: pw.BoxFit.scaleDown,
          alignment: al,
          child: t(s, size: size, a: ta, bold: b),
        );

    // عدد (ردیف و بارم): چپ‌به‌راست و بدون تغییر اندازه
    pw.Widget numText(String s, {double size = 12}) => pw.Text(s,
        textDirection: pw.TextDirection.ltr,
        textAlign: pw.TextAlign.center,
        style: pw.TextStyle(fontSize: s.length > 4 ? size - 2 : size));

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

    // چپ: مشخصات امتحان | وسط: اداره/آموزشگاه | راست: مشخصات دانش‌آموز
    final header = pw.Container(
      decoration: pw.BoxDecoration(border: pw.Border.all(width: 1.5)),
      child: pw.Row(children: [
        pw.Expanded(flex: 3, child: col(hdr.leftRows)),
        pw.Expanded(flex: 4, child: mid),
        pw.Expanded(flex: 3, child: col(hdr.rightRows)),
      ]),
    );

    pw.Widget vcell(String s) => pw.Container(
          height: 44,
          alignment: pw.Alignment.center,
          child: pw.Transform.rotateBox(
            angle: math.pi / 2,
            child: t(s, size: 11, a: pw.TextAlign.center, bold: true),
          ),
        );

    final rows = <pw.TableRow>[
      pw.TableRow(repeat: true, children: [
        vcell('بارم'),
        pw.Container(
          height: 44,
          alignment: pw.Alignment.center,
          child: t('متن سوالات', size: 13, a: pw.TextAlign.center, bold: true),
        ),
        vcell('ردیف'),
      ]),
    ];

    for (var i = 0; i < qs.length; i++) {
      final q = qs[i];
      final content = <pw.Widget>[];
      final rtlQ = q.text.trim().isEmpty ? true : isRtl(q.text);
      final lab = rtlQ ? kLabels : kLatin;

      for (final l in q.text.split('\n')) {
        if (l.trim().isNotEmpty) content.add(qline(l, size: 13));
      }
      for (final f in fxs[i]) {
        content.add(pw.SizedBox(height: 3));
        content.add(pw.Center(
          child: pw.Image(pw.MemoryImage(f.bytes),
              width: f.w * kFxScale, height: f.h * kFxScale, fit: pw.BoxFit.fill),
        ));
      }
      var hasImg = false;
      if (q.image != null && File(q.image!).existsSync()) {
        final sz = await imgSize(q.image!);
        if (sz != null) {
          hasImg = true;
          final bw = q.imgW * kCm;
          final bh = q.imgH * kCm;
          final s = math.min(bw / sz.width, bh / sz.height);
          content.add(pw.SizedBox(height: 4));
          content.add(pw.Align(
            alignment: q.imgAlign == 'l'
                ? pw.Alignment.centerLeft
                : (q.imgAlign == 'r'
                    ? pw.Alignment.centerRight
                    : pw.Alignment.center),
            child: pw.Image(pw.MemoryImage(File(q.image!).readAsBytesSync()),
                width: sz.width * s, height: sz.height * s, fit: pw.BoxFit.fill),
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
      } else if (q.type == 'desc' && !hasImg && fxs[i].isEmpty) {
        content.add(pw.SizedBox(height: 45));
      }

      rows.add(pw.TableRow(children: [
        pw.Container(
          alignment: pw.Alignment.topCenter,
          padding: const pw.EdgeInsets.all(3),
          child: numText(num2(q.points)),
        ),
        pw.Padding(
          padding: const pw.EdgeInsets.all(8),
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
    }

    // ستون‌ها از چپ به راست: بارم | متن سوالات | ردیف
    final table = pw.Table(
      border: pw.TableBorder.all(width: 1),
      columnWidths: {
        0: const pw.FixedColumnWidth(36),
        1: const pw.FlexColumnWidth(),
        2: const pw.FixedColumnWidth(28),
      },
      defaultVerticalAlignment: pw.TableCellVerticalAlignment.full,
      children: rows,
    );

    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(28),
      build: (c) => [header, table],
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

    // پاراگراف تصویر (بدون bidi تا چپ/راست دقیقاً همان چیزی باشد که کاربر خواسته)
    String addPic(List<int> bytes, int cx, int cy, String jc) {
      imgId++;
      final ext = (bytes.length > 1 && bytes[0] == 0x89) ? 'png' : 'jpeg';
      final name = 'image$imgId.$ext';
      media[name] = bytes;
      rels.write(
          '<Relationship Id="rIdImg$imgId" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/$name"/>');
      return '<w:p><w:pPr><w:spacing w:before="60" w:after="60"/><w:jc w:val="$jc"/></w:pPr>'
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

    // سربرگ (ستون اول جدول = سمت راست صفحه)
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

    // جدول سؤال‌ها (ردیف | متن | بارم)
    body.write('<w:tbl>${tblPr(8)}<w:tblGrid>'
        '<w:gridCol w:w="560"/><w:gridCol w:w="9440"/><w:gridCol w:w="700"/></w:tblGrid>');
    body.write(trX(
        tcX(pp(rp('ردیف', sz: 18, b: true), center: true), 560,
                td: true, va: 'center') +
            tcX(pp(rp('متن سوالات', sz: 22, b: true), center: true), 9440,
                va: 'center') +
            tcX(pp(rp('بارم', sz: 18, b: true), center: true), 700,
                td: true, va: 'center'),
        h: 800));

    for (var i = 0; i < qs.length; i++) {
      final q = qs[i];
      final c = StringBuffer();
      final rtlQ = q.text.trim().isEmpty ? true : isRtl(q.text);
      final lab = rtlQ ? kLabels : kLatin;

      for (final l in q.text.split('\n')) {
        if (l.trim().isEmpty) continue;
        final r = isRtl(l);
        c.write(pp(rp(l, sz: 24, rtl: r), rtl: r));
      }
      for (final f in fxs[i]) {
        c.write(addPic(f.bytes, (f.w * kFxScale * 12700).round(),
            (f.h * kFxScale * 12700).round(), 'center'));
      }
      var hasImg = false;
      if (q.image != null && File(q.image!).existsSync()) {
        final sz = await imgSize(q.image!);
        if (sz != null) {
          hasImg = true;
          final bw = q.imgW * 360000;
          final bh = q.imgH * 360000;
          final s = math.min(bw / sz.width, bh / sz.height);
          c.write(addPic(
              File(q.image!).readAsBytesSync(),
              (sz.width * s).round(),
              (sz.height * s).round(),
              q.imgAlign == 'l' ? 'left' : (q.imgAlign == 'r' ? 'right' : 'center')));
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
      }
      if (c.isEmpty) c.write('<w:p/>');
      body.write(trX(
        tcX(pp(rp(fa('${i + 1}'), sz: 22, rtl: false), center: true, rtl: false),
                560,
                va: 'center') +
            tcX(c.toString(), 9440) +
            tcX(pp(rp(num2(q.points), sz: 22, rtl: false), center: true, rtl: false),
                700),
        h: (q.type == 'desc' && !hasImg && fxs[i].isEmpty) ? 1400 : 600,
      ));
    }
    body.write('</w:tbl><w:p/>');

    const ns =
        'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
        'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" '
        'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
        'xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"';
    const xmlHead = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>';

    final documentXml = '$xmlHead<w:document $ns><w:body>$body'
        '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
        '<w:pgMar w:top="567" w:right="567" w:bottom="567" w:left="567" w:header="400" w:footer="400" w:gutter="0"/>'
        '<w:bidi/></w:sectPr></w:body></w:document>';

    const contentTypes =
        '$xmlHead<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Default Extension="png" ContentType="image/png"/>'
        '<Default Extension="jpeg" ContentType="image/jpeg"/>'
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        '</Types>';

    const rootRels =
        '$xmlHead<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
        '</Relationships>';

    final docRels =
        '$xmlHead<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">$rels</Relationships>';

    final arc = Archive();
    void add(String n, List<int> b) => arc.addFile(ArchiveFile(n, b.length, b));
    add('[Content_Types].xml', utf8.encode(contentTypes));
    add('_rels/.rels', utf8.encode(rootRels));
    add('word/document.xml', utf8.encode(documentXml));
    add('word/_rels/document.xml.rels', utf8.encode(docRels));
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
        Padding(
          padding: const EdgeInsets.all(12),
          child: Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: ListTile(
              leading: const Icon(Icons.badge, color: kBlue),
              title: Text(hdr['school'].isEmpty ? 'سربرگ آزمون' : hdr['school']),
              subtitle: Text(
                  'درس: ${hdr['subject']}   پایه: ${hdr['grade']}   (برای ویرایش بزنید)'),
              trailing: const Icon(Icons.edit, color: kBlue),
              onTap: editHeader,
            ),
          ),
        ),
        Text('تعداد سؤال: ${fa('${qs.length}')}   |   جمع بارم: ${num2(total)}',
            style: const TextStyle(color: kBlue, fontWeight: FontWeight.bold)),
        Expanded(
          child: qs.isEmpty
              ? const Center(child: Text('هنوز سؤالی ندارید'))
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 90),
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

class Editor extends StatefulWidget {
  final Q? q;
  const Editor({super.key, this.q});
  @override
  State<Editor> createState() => _EditorState();
}

class _EditorState extends State<Editor> {
  String type = 'mc';
  String? image;
  double imgW = 10, imgH = 6;
  String imgAlign = 'c';
  final text = TextEditingController();
  final formula = TextEditingController();
  final pts = TextEditingController(text: '1');
  final opts = List.generate(4, (_) => TextEditingController());

  static const syms = <(String, String, int)>[
    ('a/b', r'\frac{}{}', 3),
    ('xⁿ', r'^{}', 1),
    ('xₙ', r'_{}', 1),
    ('√', r'\sqrt{}', 1),
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
  ];

  @override
  void initState() {
    super.initState();
    final q = widget.q;
    if (q != null) {
      type = q.type;
      text.text = q.text;
      formula.text = q.formula;
      pts.text = q.points.toString();
      image = q.image;
      imgW = q.imgW.clamp(1.0, 16.0).toDouble();
      imgH = q.imgH.clamp(1.0, 15.0).toDouble();
      imgAlign = q.imgAlign;
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
    final lines =
        formula.text.split('\n').where((e) => e.trim().isNotEmpty).toList();
    return Scaffold(
      appBar: bar('سؤال'),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'mc', label: Text('چهارگزینه‌ای')),
            ButtonSegment(value: 'tf', label: Text('صحیح/غلط')),
            ButtonSegment(value: 'desc', label: Text('تشریحی')),
          ],
          selected: {type},
          onSelectionChanged: (s) => setState(() => type = s.first),
        ),
        const SizedBox(height: 16),
        field(text, 'متن سؤال (اگر صورت سؤال در تصویر است، خالی بگذارید)',
            lines: 2),

        // ---- باکس فرمول ----
        const Text('باکس فرمول و عبارت ریاضی (اختیاری)',
            style: TextStyle(fontWeight: FontWeight.bold, color: kBlue)),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 0, children: [
          for (final s in syms)
            ActionChip(
              label: Text(s.$1, style: const TextStyle(fontSize: 16)),
              onPressed: () => ins(s.$2, s.$3),
            ),
        ]),
        const SizedBox(height: 6),
        TextField(
          controller: formula,
          textDirection: TextDirection.ltr,
          minLines: 2,
          maxLines: 5,
          onChanged: (_) => setState(() {}),
          style: const TextStyle(fontFamily: 'monospace'),
          decoration: InputDecoration(
            filled: true,
            fillColor: Colors.white,
            labelText: 'هر خط یک فرمول، مثال: x^{2}+\\frac{1}{2}',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        for (final l in lines)
          Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
                color: Colors.white, borderRadius: BorderRadius.circular(12)),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Math.tex(l.trim(), textStyle: const TextStyle(fontSize: 22)),
              ),
            ),
          ),
        const SizedBox(height: 16),

        // ---- تصویر ----
        OutlinedButton.icon(
          onPressed: choose,
          icon: const Icon(Icons.image),
          label: Text(image == null ? 'درج تصویر' : 'تغییر تصویر'),
        ),
        if (image != null) ...[
          const SizedBox(height: 8),
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
          TextButton.icon(
            onPressed: () => setState(() => image = null),
            icon: const Icon(Icons.delete, color: Colors.redAccent),
            label: const Text('حذف تصویر'),
          ),
        ],
        const SizedBox(height: 12),
        if (type == 'mc')
          for (var i = 0; i < 4; i++) field(opts[i], 'گزینه ${kLabels[i]}'),
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
                ));
          },
          child: const Text('ثبت سؤال', style: TextStyle(fontSize: 16)),
        ),
      ]),
    );
  }
}
