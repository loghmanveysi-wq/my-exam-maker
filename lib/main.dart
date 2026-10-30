import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
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

class Hdr {
  String bism, org, title, subject, grade, teacher, date, duration;
  String? logo;
  Hdr({
    this.bism = 'به نام خدا',
    this.org = '',
    this.title = 'آزمون',
    this.subject = '',
    this.grade = '',
    this.teacher = '',
    this.date = '',
    this.duration = '',
    this.logo,
  });
  Map<String, dynamic> toJson() => {
        'bism': bism,
        'org': org,
        'title': title,
        'subject': subject,
        'grade': grade,
        'teacher': teacher,
        'date': date,
        'duration': duration,
        'logo': logo,
      };
  factory Hdr.fromJson(Map<String, dynamic> j) => Hdr(
        bism: j['bism'] ?? '',
        org: j['org'] ?? '',
        title: j['title'] ?? '',
        subject: j['subject'] ?? '',
        grade: j['grade'] ?? '',
        teacher: j['teacher'] ?? '',
        date: j['date'] ?? '',
        duration: j['duration'] ?? '',
        logo: j['logo'],
      );
}

String typeName(String t) =>
    t == 'mc' ? 'چهارگزینه‌ای' : (t == 'tf' ? 'صحیح/غلط' : 'تشریحی');

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
    } else {
      hdr.title = sp!.getString('title') ?? 'آزمون';
    }
    setState(() {});
  }

  void save() {
    sp?.setString('qs', jsonEncode(qs.map((e) => e.toJson()).toList()));
    sp?.setString('hdr', jsonEncode(hdr.toJson()));
  }

  double get total => qs.fold(0.0, (a, b) => a + b.points);

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

  Future<void> exportPdf() async {
    if (qs.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('ابتدا سؤال اضافه کنید')));
      return;
    }
    final data = await rootBundle.load('assets/fonts/Vazir.ttf');
    final font = pw.Font.ttf(data);
    final doc = pw.Document(theme: pw.ThemeData.withFont(base: font, bold: font));

    pw.Widget t(String s,
            {double size = 12, pw.TextAlign a = pw.TextAlign.right}) =>
        pw.Text(s,
            textDirection: pw.TextDirection.rtl,
            textAlign: a,
            style: pw.TextStyle(fontSize: size));

    pw.Widget cell(String label, String value) => pw.Expanded(
          child: pw.Container(
            padding: const pw.EdgeInsets.all(5),
            decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.5)),
            child: t('$label: $value', size: 11),
          ),
        );

    pw.Widget? logoW;
    if (hdr.logo != null && File(hdr.logo!).existsSync()) {
      logoW = pw.Image(pw.MemoryImage(File(hdr.logo!).readAsBytesSync()),
          fit: pw.BoxFit.contain);
    }

    final header = pw.Column(children: [
      if (hdr.bism.isNotEmpty)
        pw.Center(child: t(hdr.bism, size: 11, a: pw.TextAlign.center)),
      pw.SizedBox(height: 6),
      pw.Container(
        padding: const pw.EdgeInsets.all(8),
        decoration: pw.BoxDecoration(border: pw.Border.all(width: 1)),
        child: pw.Row(textDirection: pw.TextDirection.rtl, children: [
          pw.SizedBox(width: 60, height: 60, child: logoW),
          pw.Expanded(
            child: pw.Column(children: [
              if (hdr.org.isNotEmpty) t(hdr.org, size: 14, a: pw.TextAlign.center),
              pw.SizedBox(height: 4),
              t(hdr.title, size: 18, a: pw.TextAlign.center),
            ]),
          ),
          pw.SizedBox(width: 60),
        ]),
      ),
      pw.Row(textDirection: pw.TextDirection.rtl, children: [
        cell('درس', hdr.subject),
        cell('پایه', hdr.grade),
        cell('دبیر', hdr.teacher),
      ]),
      pw.Row(textDirection: pw.TextDirection.rtl, children: [
        cell('تاریخ', hdr.date),
        cell('مدت', hdr.duration),
        cell('نام و نام خانوادگی', ''),
      ]),
      pw.SizedBox(height: 6),
      pw.Center(
          child: t('جمع بارم: ${num2(total)} نمره', a: pw.TextAlign.center)),
      pw.Divider(),
    ]);

    final items = <pw.Widget>[];
    for (var i = 0; i < qs.length; i++) {
      final q = qs[i];
      items.add(pw.SizedBox(height: 10));
      items.add(t('${fa('${i + 1}')}. ${q.text}   (${num2(q.points)} نمره)',
          size: 13));
      if (q.image != null && File(q.image!).existsSync()) {
        items.add(pw.SizedBox(height: 6));
        items.add(pw.Center(
          child: pw.ConstrainedBox(
            constraints: const pw.BoxConstraints(maxWidth: 480, maxHeight: 230),
            child: pw.Image(pw.MemoryImage(File(q.image!).readAsBytesSync()),
                fit: pw.BoxFit.contain),
          ),
        ));
      }
      if (q.type == 'mc') {
        for (var k = 0; k < 4; k++) {
          items.add(pw.Padding(
              padding: const pw.EdgeInsets.only(top: 4, right: 14),
              child: t('${kLabels[k]}) ${q.options[k]}')));
        }
      } else if (q.type == 'tf') {
        items.add(pw.Padding(
            padding: const pw.EdgeInsets.only(top: 4, right: 14),
            child: t('(    ) صحیح          (    ) غلط')));
      } else {
        items.add(pw.SizedBox(height: 60));
      }
    }

    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      textDirection: pw.TextDirection.rtl,
      margin: const pw.EdgeInsets.all(32),
      build: (c) => [header, ...items],
    ));
    final bytes = await doc.save();
    await Printing.sharePdf(bytes: bytes, filename: 'azmoon.pdf');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: bar('آزمون بساز', actions: [
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
              title: Text(hdr.title),
              subtitle: Text(hdr.org.isEmpty ? 'سربرگ آزمون' : hdr.org),
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
                        title: Text(q.text,
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
  static const labels = {
    'bism': 'عبارت بالای برگه (مثلاً به نام خدا)',
    'org': 'نام مدرسه / دانشگاه / مؤسسه',
    'title': 'عنوان آزمون',
    'subject': 'درس',
    'grade': 'پایه / کلاس',
    'teacher': 'نام دبیر / استاد',
    'date': 'تاریخ آزمون',
    'duration': 'مدت آزمون (مثلاً ۶۰ دقیقه)',
  };
  late final Map<String, TextEditingController> c;
  String? logo;

  @override
  void initState() {
    super.initState();
    final j = widget.h.toJson();
    c = {
      for (final k in labels.keys) k: TextEditingController(text: j[k] as String)
    };
    logo = widget.h.logo;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: bar('سربرگ آزمون'),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        for (final k in labels.keys) field(c[k]!, labels[k]!),
        OutlinedButton.icon(
          onPressed: () async {
            final p = await pickImage();
            if (p != null) setState(() => logo = p);
          },
          icon: const Icon(Icons.image),
          label: Text(logo == null ? 'درج لوگو (اختیاری)' : 'تغییر لوگو'),
        ),
        if (logo != null) ...[
          const SizedBox(height: 8),
          Image.file(File(logo!), height: 90, fit: BoxFit.contain),
          TextButton.icon(
            onPressed: () => setState(() => logo = null),
            icon: const Icon(Icons.delete, color: Colors.redAccent),
            label: const Text('حذف لوگو'),
          ),
        ],
        const SizedBox(height: 12),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: kBlue, padding: const EdgeInsets.all(16)),
          onPressed: () {
            final m = {for (final k in labels.keys) k: c[k]!.text.trim()};
            m['logo'] = logo ?? '';
            final h = Hdr.fromJson(m);
            h.logo = logo;
            Navigator.pop(context, h);
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
        field(text, 'متن سؤال', lines: 2),
        if (type == 'mc')
          for (var i = 0; i < 4; i++) field(opts[i], 'گزینه ${kLabels[i]}'),
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
        field(pts, 'بارم (نمره)',
            kb: const TextInputType.numberWithOptions(decimal: true)),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: kBlue, padding: const EdgeInsets.all(16)),
          onPressed: () {
            if (text.text.trim().isEmpty) return;
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
