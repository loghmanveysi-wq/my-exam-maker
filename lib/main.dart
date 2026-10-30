import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

class Q {
  String type; // mc, tf, desc
  String text;
  List<String> options;
  double points;
  Q({required this.type, required this.text, List<String>? options, this.points = 1})
      : options = options ?? ['', '', '', ''];
  Map<String, dynamic> toJson() =>
      {'type': type, 'text': text, 'options': options, 'points': points};
  factory Q.fromJson(Map<String, dynamic> j) => Q(
      type: j['type'],
      text: j['text'],
      options: List<String>.from(j['options']),
      points: (j['points'] as num).toDouble());
}

String typeName(String t) =>
    t == 'mc' ? 'چهارگزینه‌ای' : (t == 'tf' ? 'صحیح/غلط' : 'تشریحی');

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
  final title = TextEditingController(text: 'آزمون');
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
    title.text = sp!.getString('title') ?? 'آزمون';
    setState(() {});
  }

  void save() {
    sp?.setString('qs', jsonEncode(qs.map((e) => e.toJson()).toList()));
    sp?.setString('title', title.text);
  }

  double get total => qs.fold(0.0, (a, b) => a + b.points);

  Future<void> edit([int? i]) async {
    final r = await Navigator.push<Q>(
        context, MaterialPageRoute(builder: (_) => Editor(q: i == null ? null : qs[i])));
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

  Future<void> exportPdf() async {
    if (qs.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('ابتدا سؤال اضافه کنید')));
      return;
    }
    final data = await rootBundle.load('assets/fonts/Vazir.ttf');
    final font = pw.Font.ttf(data);
    final doc = pw.Document(theme: pw.ThemeData.withFont(base: font, bold: font));
    pw.Widget t(String s, {double size = 12, pw.TextAlign a = pw.TextAlign.right}) =>
        pw.Text(s, textDirection: pw.TextDirection.rtl, textAlign: a, style: pw.TextStyle(fontSize: size));

    final items = <pw.Widget>[];
    for (var i = 0; i < qs.length; i++) {
      final q = qs[i];
      items.add(pw.SizedBox(height: 10));
      items.add(t('${fa('${i + 1}')}. ${q.text}   (${num2(q.points)} نمره)', size: 13));
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
      build: (c) => [
        pw.Center(child: t(title.text, size: 20, a: pw.TextAlign.center)),
        pw.SizedBox(height: 4),
        pw.Center(
            child: t('جمع بارم: ${num2(total)} نمره', a: pw.TextAlign.center)),
        pw.Divider(),
        ...items,
      ],
    ));
    final bytes = await doc.save();
    await Printing.sharePdf(bytes: bytes, filename: 'azmoon.pdf');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        foregroundColor: Colors.white,
        title: const Text('آزمون بساز', style: TextStyle(fontWeight: FontWeight.bold)),
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(colors: [Color(0xFF1E88E5), Color(0xFF0D47A1)]),
          ),
        ),
        actions: [
          IconButton(
              icon: const Icon(Icons.picture_as_pdf),
              tooltip: 'خروجی PDF',
              onPressed: exportPdf),
        ],
      ),
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
          child: TextField(
            controller: title,
            onChanged: (_) => save(),
            decoration: InputDecoration(
              filled: true,
              fillColor: Colors.white,
              labelText: 'عنوان آزمون',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
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
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      child: ListTile(
                        leading: CircleAvatar(
                            backgroundColor: kBlue,
                            foregroundColor: Colors.white,
                            child: Text(fa('${i + 1}'))),
                        title: Text(q.text, maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text('${typeName(q.type)} - ${num2(q.points)} نمره'),
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

class Editor extends StatefulWidget {
  final Q? q;
  const Editor({super.key, this.q});
  @override
  State<Editor> createState() => _EditorState();
}

class _EditorState extends State<Editor> {
  String type = 'mc';
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
      for (var i = 0; i < 4; i++) {
        opts[i].text = q.options[i];
      }
    }
  }

  Widget field(TextEditingController c, String label, {int lines = 1, TextInputType? kb}) =>
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('سؤال'),
        foregroundColor: Colors.white,
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(colors: [Color(0xFF1E88E5), Color(0xFF0D47A1)]),
          ),
        ),
      ),
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
        field(pts, 'بارم (نمره)', kb: const TextInputType.numberWithOptions(decimal: true)),
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
                ));
          },
          child: const Text('ثبت سؤال', style: TextStyle(fontSize: 16)),
        ),
      ]),
    );
  }
}
