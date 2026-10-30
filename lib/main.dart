import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:archive/archive.dart' show Archive, ArchiveFile, ZipEncoder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

String fa(String s) {
  const e = '0123456789';
  const f = '۰۱۲۳۴۵۶۷۸۹';
  for (var i = 0; i < 10; i++) {
    s = s.replaceAll(e[i], f[i]);
  }
  return s.replaceAll('.', '٫');
}

String num2(double p) => fa(p % 1 == 0 ? p.toInt().toString() : p.toString());

Future<String?> pickImage() async {
  final x = await ImagePicker()
      .pickImage(source: ImageSource.gallery, maxWidth: 1600, imageQuality: 85);
  if (x == null) return null;
  final dir = await getApplicationDocumentsDirectory();
  final path = '${dir.path}/img_${DateTime.now().microsecondsSinceEpoch}.jpg';
  await x.saveTo(path);
  return path;
}

// ---------------- مدل سؤال ----------------
class Q {
  String type; // mc, tf, desc
  String text;
  List<String> options;
  double points;
  String? image;
  Q({
    required this.type,
    required this.text,
    List<String>? options,
    this.points = 1,
    this.image,
  }) : options = options ?? ['', '', '', ''];
  Map<String, dynamic> toJson() => {
        'type': type,
        'text': text,
        'options': options,
        'points': points,
        'image': image,
      };
  factory Q.fromJson(Map<String, dynamic> j) => Q(
        type: j['type'],
        text: j['text'],
        options: List<String>.from(j['options']),
        points: (j['points'] as num).toDouble(),
        image: j['image'],
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

String rp(String s, {int sz = 22, bool b = false}) =>
    '<w:r><w:rPr><w:rFonts w:ascii="Tahoma" w:hAnsi="Tahoma" w:cs="Tahoma"/>'
    '${b ? '<w:b/><w:bCs/>' : ''}<w:sz w:val="$sz"/><w:szCs w:val="$sz"/><w:rtl/></w:rPr>'
    '<w:t xml:space="preserve">${esc(s)}</w:t></w:r>';

String pp(String inner, {bool center = false}) =>
    '<w:p><w:pPr><w:bidi/><w:spacing w:before="40" w:after="40"/>'
    '${center ? '<w:jc w:val="center"/>' : ''}</w:pPr>$inner</w:p>';

String tcX(String inner, int w, {String vm = '', String va = 'top'}) =>
    '<w:tc><w:tcPr><w:tcW w:w="$w" w:type="dxa"/>$vm<w:vAlign w:val="$va"/></w:tcPr>$inner</w:tc>';

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

  // ---------------- خروجی PDF ----------------
  Future<void> exportPdf() async {
    if (qs.isEmpty) {
      msg('ابتدا سؤال اضافه کنید');
      return;
    }
    final data = await rootBundle.load('assets/fonts/Vazir.ttf');
    final font = pw.Font.ttf(data);
    final doc = pw.Document(theme: pw.ThemeData.withFont(base: font, bold: font));

    pw.Widget t(String s,
            {double size = 11, pw.TextAlign a = pw.TextAlign.right}) =>
        pw.Text(s,
            textDirection: pw.TextDirection.rtl,
            textAlign: a,
            style: pw.TextStyle(fontSize: size));

    final side = pw.BorderSide(width: 0.8);

    pw.Widget hc(String s, {bool last = false}) => pw.Container(
          height: 24,
          alignment: pw.Alignment.centerRight,
          padding: const pw.EdgeInsets.symmetric(horizontal: 6),
          decoration: last ? null : pw.BoxDecoration(border: pw.Border(bottom: side)),
          child: t(s, size: 10.5),
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
      height: 120,
      decoration: pw.BoxDecoration(border: pw.Border(left: side, right: side)),
      child: pw.Column(
        mainAxisAlignment: pw.MainAxisAlignment.center,
        mainAxisSize: pw.MainAxisSize.min,
        children: [
          for (final l in hdr.midLines)
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
              child: t(l, size: 9.5, a: pw.TextAlign.center),
            ),
        ],
      ),
    );

    final header = pw.Container(
      decoration: pw.BoxDecoration(border: pw.Border.all(width: 1.5)),
      child: pw.Row(children: [
        pw.Expanded(flex: 3, child: col(hdr.leftRows)),
        pw.Expanded(flex: 4, child: mid),
        pw.Expanded(flex: 3, child: col(hdr.rightRows)),
      ]),
    );

    pw.Widget hcell(String s) => pw.Container(
          padding: const pw.EdgeInsets.all(4),
          alignment: pw.Alignment.center,
          child: t(s, size: 11, a: pw.TextAlign.center),
        );

    final rows = <pw.TableRow>[
      pw.TableRow(
          repeat: true, children: [hcell('بارم'), hcell('متن سوالات'), hcell('ردیف')]),
    ];

    for (var i = 0; i < qs.length; i++) {
      final q = qs[i];
      final content = <pw.Widget>[];
      if (q.text.isNotEmpty) content.add(t(q.text, size: 11.5));
      if (q.image != null && File(q.image!).existsSync()) {
        content.add(pw.SizedBox(height: 4));
        content.add(pw.Center(
          child: pw.ConstrainedBox(
            constraints: const pw.BoxConstraints(maxWidth: 420, maxHeight: 250),
            child: pw.Image(pw.MemoryImage(File(q.image!).readAsBytesSync()),
                fit: pw.BoxFit.contain),
          ),
        ));
      }
      if (q.type == 'mc' && q.options.any((o) => o.isNotEmpty)) {
        content.add(pw.SizedBox(height: 4));
        final short = q.options.every((o) => o.length <= 14);
        if (short) {
          content.add(pw.Row(children: [
            for (var k = 3; k >= 0; k--)
              pw.Expanded(child: t('${kLabels[k]}) ${q.options[k]}', size: 10.5)),
          ]));
        } else {
          for (var k = 0; k < 4; k++) {
            content.add(t('${kLabels[k]}) ${q.options[k]}', size: 10.5));
          }
        }
      } else if (q.type == 'tf') {
        content.add(pw.SizedBox(height: 4));
        content.add(t('(    ) صحیح          (    ) غلط', size: 10.5));
      } else if (q.type == 'desc' && q.image == null) {
        content.add(pw.SizedBox(height: 45));
      }
      rows.add(pw.TableRow(children: [
        pw.Container(
          alignment: pw.Alignment.topCenter,
          padding: const pw.EdgeInsets.all(6),
          child: t(num2(q.points), a: pw.TextAlign.center),
        ),
        pw.Container(
          alignment: pw.Alignment.topRight,
          padding: const pw.EdgeInsets.all(8),
          child: pw.Column(
            mainAxisSize: pw.MainAxisSize.min,
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: content,
          ),
        ),
        pw.Container(
          alignment: pw.Alignment.center,
          padding: const pw.EdgeInsets.all(6),
          child: t(fa('${i + 1}'), a: pw.TextAlign.center),
        ),
      ]));
    }

    final table = pw.Table(
      border: pw.TableBorder.all(width: 1),
      columnWidths: {
        0: const pw.FixedColumnWidth(42),
        1: const pw.FlexColumnWidth(),
        2: const pw.FixedColumnWidth(36),
      },
      defaultVerticalAlignment: pw.TableCellVerticalAlignment.full,
      children: rows,
    );

    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      textDirection: pw.TextDirection.rtl,
      margin: const pw.EdgeInsets.all(28),
      build: (c) => [header, table],
    ));
    final bytes = await doc.save();
    await Printing.sharePdf(bytes: bytes, filename: 'azmoon.pdf');
  }

  // ---------------- خروجی Word ----------------
  Future<void> exportDocx() async {
    if (qs.isEmpty) {
      msg('ابتدا سؤال اضافه کنید');
      return;
    }
    final media = <String, List<int>>{};
    final rels = StringBuffer();
    var imgId = 0;

    Future<String> drawing(String path) async {
      final bytes = File(path).readAsBytesSync();
      final im = await decodeImageFromList(Uint8List.fromList(bytes));
      imgId++;
      final ext = (bytes.length > 1 && bytes[0] == 0x89) ? 'png' : 'jpeg';
      final name = 'image$imgId.$ext';
      media[name] = bytes;
      rels.write(
          '<Relationship Id="rIdImg$imgId" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/$name"/>');
      const maxW = 5040000.0; // 14cm
      const maxH = 2700000.0; // 7.5cm
      final s = math.min(maxW / im.width, maxH / im.height);
      final cx = (im.width * s).round();
      final cy = (im.height * s).round();
      return '<w:p><w:pPr><w:bidi/><w:spacing w:before="60" w:after="60"/><w:jc w:val="center"/></w:pPr>'
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

    // سربرگ
    final midParas =
        hdr.midLines.map((l) => pp(rp(l, sz: 18, b: true), center: true)).join();
    final right = hdr.rightRows;
    final left = hdr.leftRows;
    body.write('<w:tbl>${tblPr(8)}<w:tblGrid>'
        '<w:gridCol w:w="3300"/><w:gridCol w:w="4100"/><w:gridCol w:w="3300"/></w:tblGrid>');
    for (var i = 0; i < 5; i++) {
      final midCell = i == 0
          ? tcX(midParas, 4100, vm: '<w:vMerge w:val="restart"/>', va: 'center')
          : tcX('<w:p/>', 4100, vm: '<w:vMerge/>');
      body.write(trX(
        tcX(pp(rp(right[i], sz: 20, b: true)), 3300, va: 'center') +
            midCell +
            tcX(pp(rp(left[i], sz: 20, b: true)), 3300, va: 'center'),
        h: 420,
      ));
    }
    body.write('</w:tbl>');
    body.write(
        '<w:p><w:pPr><w:spacing w:before="0" w:after="0" w:line="20" w:lineRule="exact"/></w:pPr></w:p>');

    // جدول سؤال‌ها
    body.write('<w:tbl>${tblPr(8)}<w:tblGrid>'
        '<w:gridCol w:w="700"/><w:gridCol w:w="8900"/><w:gridCol w:w="1100"/></w:tblGrid>');
    body.write(trX(
        tcX(pp(rp('ردیف', sz: 20, b: true), center: true), 700, va: 'center') +
            tcX(pp(rp('متن سوالات', sz: 20, b: true), center: true), 8900,
                va: 'center') +
            tcX(pp(rp('بارم', sz: 20, b: true), center: true), 1100, va: 'center'),
        h: 380));

    for (var i = 0; i < qs.length; i++) {
      final q = qs[i];
      final c = StringBuffer();
      if (q.text.isNotEmpty) {
        for (final l in q.text.split('\n')) {
          c.write(pp(rp(l, sz: 22)));
        }
      }
      final hasImg = q.image != null && File(q.image!).existsSync();
      if (hasImg) c.write(await drawing(q.image!));
      if (q.type == 'mc' && q.options.any((o) => o.isNotEmpty)) {
        for (var k = 0; k < 4; k++) {
          c.write(pp(rp('${kLabels[k]}) ${q.options[k]}', sz: 21)));
        }
      } else if (q.type == 'tf') {
        c.write(pp(rp('(     ) صحیح          (     ) غلط', sz: 21)));
      }
      if (c.isEmpty) c.write('<w:p/>');
      body.write(trX(
        tcX(pp(rp(fa('${i + 1}'), sz: 22), center: true), 700, va: 'center') +
            tcX(c.toString(), 8900) +
            tcX(pp(rp(num2(q.points), sz: 22), center: true), 1100),
        h: (q.type == 'desc' && !hasImg) ? 1400 : 600,
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

    const contentTypes = '$xmlHead<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Default Extension="png" ContentType="image/png"/>'
        '<Default Extension="jpeg" ContentType="image/jpeg"/>'
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        '</Types>';

    const rootRels = '$xmlHead<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
        '</Relationships>';

    final docRels = '$xmlHead<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">$rels</Relationships>';

    final arc = Archive();
    void add(String n, List<int> b) => arc.addFile(ArchiveFile(n, b.length, b));
    add('[Content_Types].xml', utf8.encode(contentTypes));
    add('_rels/.rels', utf8.encode(rootRels));
    add('word/document.xml', utf8.encode(documentXml));
    add('word/_rels/document.xml.rels', utf8.encode(docRels));
    media.forEach((k, v) => add('word/media/$k', v));

    final z = ZipEncoder().encode(arc) as List<int>;
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/azmoon.docx');
    await f.writeAsBytes(z, flush: true);
    await Share.shareXFiles([
      XFile(f.path,
          mimeType:
              'application/vnd.openxmlformats-officedocument.wordprocessingml.document')
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: bar('آزمون بساز', actions: [
        IconButton(
            icon: const Icon(Icons.description),
            tooltip: 'خروجی Word',
            onPressed: exportDocx),
        IconButton(
            icon: const Icon(Icons.picture_as_pdf),
            tooltip: 'خروجی PDF',
            onPressed: exportPdf),
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
                        title: Text(q.text.isEmpty ? 'سؤال تصویری' : q.text,
                            maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                            '${typeName(q.type)} - ${num2(q.points)} نمره${q.image != null ? ' - دارای تصویر' : ''}'),
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
  final text = TextEditingController();
  final pts = TextEditingController(text: '1');
  final opts = List.generate(4, (_) => TextEditingController());

  @override
  void initState() {
    super.initState();
    final q = widget.q;
    if (q != null) {
      type = q.type;
      text.text = q.text;
      pts.text = q.points.toString();
      image = q.image;
      for (var i = 0; i < 4; i++) {
        opts[i].text = q.options[i];
      }
    }
  }

  @override
  Widget build(BuildContext context) {
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
        OutlinedButton.icon(
          onPressed: () async {
            final p = await pickImage();
            if (p != null) setState(() => image = p);
          },
          icon: const Icon(Icons.image),
          label: Text(image == null ? 'درج تصویر' : 'تغییر تصویر'),
        ),
        if (image != null) ...[
          const SizedBox(height: 8),
          Image.file(File(image!), height: 160, fit: BoxFit.contain),
          TextButton.icon(
            onPressed: () => setState(() => image = null),
            icon: const Icon(Icons.delete, color: Colors.redAccent),
            label: const Text('حذف تصویر'),
          ),
        ],
        const SizedBox(height: 12),
        if (type == 'mc')
          for (var i = 0; i < 4; i++) field(opts[i], 'گزینه ${kLabels[i]}'),
        field(pts, 'بارم (نمره)',
            kb: const TextInputType.numberWithOptions(decimal: true)),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: kBlue, padding: const EdgeInsets.all(16)),
          onPressed: () {
            if (text.text.trim().isEmpty && image == null) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('متن سؤال یا تصویر سؤال را وارد کنید')));
              return;
            }
            Navigator.pop(
                context,
                Q(
                  type: type,
                  text: text.text.trim(),
                  options: opts.map((e) => e.text.trim()).toList(),
                  points: double.tryParse(pts.text.replaceAll('٫', '.')) ?? 1,
                  image: image,
                ));
          },
          child: const Text('ثبت سؤال', style: TextStyle(fontSize: 16)),
        ),
      ]),
    );
  }
}
