import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ───────────── Utilidades ─────────────
const dayShort = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];
const dayFull = ['Lunes', 'Martes', 'Miércoles', 'Jueves', 'Viernes', 'Sábado', 'Domingo'];
String fd(DateTime d) => '${dayShort[d.weekday - 1]} ${d.day}/${d.month}';
String fn(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
double e1(double w, int r) => w * (1 + r / 30); // 1RM estimado (Epley)
String dl(Routine r) => r.days.isEmpty ? '' : ' · ${(List.of(r.days)..sort()).map((d) => dayShort[d - 1]).join(', ')}';
TextStyle mu(BuildContext c) => TextStyle(color: Theme.of(c).colorScheme.onSurface.withOpacity(.6), fontSize: 13);
const bold = TextStyle(fontWeight: FontWeight.w700, fontSize: 16);

Future<void> confirm(BuildContext c, String msg, VoidCallback ok) async {
  final r = await showDialog<bool>(
    context: c,
    builder: (ctx) => AlertDialog(title: Text(msg), actions: [
      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
      TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Sí')),
    ]),
  );
  if (r == true) ok();
}

// ───────────── Modelos ─────────────
class SetRec {
  double w;
  int r;
  bool done;
  SetRec(this.w, this.r, [this.done = false]);
  Map<String, dynamic> toJson() => {'w': w, 'r': r, 'd': done};
  factory SetRec.fromJson(Map j) => SetRec((j['w'] as num).toDouble(), (j['r'] as num).toInt(), j['d'] == true);
}

class ExLog {
  String n, note;
  List<SetRec> sets;
  ExLog(this.n, this.sets, [this.note = '']);
  Map<String, dynamic> toJson() => {'n': n, 'note': note, 'sets': sets.map((s) => s.toJson()).toList()};
  factory ExLog.fromJson(Map j) =>
      ExLog(j['n'], (j['sets'] as List).map((s) => SetRec.fromJson(s)).toList(), j['note'] ?? '');
}

class Workout {
  String id, name;
  DateTime date;
  List<ExLog> ex;
  Workout(this.id, this.name, this.date, this.ex);
  double get volume => ex.fold(0.0, (a, e) => a + e.sets.fold(0.0, (b, s) => b + s.w * s.r));
  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'date': date.toIso8601String(), 'ex': ex.map((e) => e.toJson()).toList()};
  factory Workout.fromJson(Map j) => Workout(j['id'], j['name'], DateTime.parse(j['date']),
      (j['ex'] as List).map((e) => ExLog.fromJson(e)).toList());
}

class Routine {
  String id, name;
  List<String> ex;
  List<int> days; // 1 = lunes ... 7 = domingo
  Routine(this.id, this.name, this.ex, this.days);
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'ex': ex, 'days': days};
  factory Routine.fromJson(Map j) =>
      Routine(j['id'], j['name'], List<String>.from(j['ex']), List<int>.from(j['days'] ?? []));
}

class Rec {
  final String ex;
  final DateTime date;
  final double w, e, gain;
  final int r;
  Rec(this.ex, this.date, this.w, this.r, this.e, this.gain);
}

// ───────────── Almacenamiento y lógica ─────────────
class Store extends ChangeNotifier {
  late SharedPreferences p;
  List<Routine> routines = [];
  List<Workout> logs = [];
  Workout? draft;
  int restSec = 90;

  Future<void> load() async {
    p = await SharedPreferences.getInstance();
    final s = p.getString('gymlog');
    if (s == null) {
      routines = [
        Routine('r1', 'Empuje', ['Press banca', 'Press militar', 'Fondos', 'Extensión de tríceps'], [1]),
        Routine('r2', 'Tirón', ['Dominadas', 'Remo con barra', 'Curl de bíceps'], [2]),
        Routine('r3', 'Pierna', ['Sentadilla', 'Peso muerto rumano', 'Prensa', 'Elevación de talones'], [3]),
      ];
      return;
    }
    final j = jsonDecode(s) as Map;
    restSec = (j['rest'] as num?)?.toInt() ?? 90;
    routines = (j['routines'] as List).map((e) => Routine.fromJson(e)).toList();
    logs = (j['logs'] as List).map((e) => Workout.fromJson(e)).toList();
    if (j['draft'] != null) draft = Workout.fromJson(j['draft']);
  }

  void save({bool notify = true}) {
    p.setString('gymlog', jsonEncode({
      'routines': routines.map((r) => r.toJson()).toList(),
      'logs': logs.map((w) => w.toJson()).toList(),
      'draft': draft?.toJson(),
      'rest': restSec,
    }));
    if (notify) notifyListeners();
  }

  List<Workout> get sorted => [...logs]..sort((a, b) => a.date.compareTo(b.date));

  /// Récord = un entrenamiento que supera el mejor 1RM estimado previo de ese ejercicio.
  List<Rec> get records {
    final best = <String, double>{};
    final out = <Rec>[];
    for (final w in sorted) {
      for (final e in w.ex) {
        SetRec? top;
        for (final x in e.sets) {
          if (top == null || e1(x.w, x.r) > e1(top.w, top.r)) top = x;
        }
        if (top == null) continue;
        final v = e1(top.w, top.r);
        final prev = best[e.n];
        if (prev != null && v > prev + 0.01) out.add(Rec(e.n, w.date, top.w, top.r, v, v - prev));
        if (prev == null || v > prev) best[e.n] = v;
      }
    }
    return out.reversed.toList();
  }

  ExLog? lastOf(String n) {
    for (final w in sorted.reversed) {
      for (final e in w.ex) {
        if (e.n == n) return e;
      }
    }
    return null;
  }

  ExLog mkEx(String n) {
    final l = lastOf(n);
    return ExLog(n, l == null ? [SetRec(0, 0)] : l.sets.map((s) => SetRec(s.w, s.r)).toList(), l?.note ?? '');
  }

  void startWorkout(Routine? r) {
    draft = Workout(DateTime.now().millisecondsSinceEpoch.toString(), r?.name ?? 'Entrenamiento libre',
        DateTime.now(), (r?.ex ?? <String>[]).map(mkEx).toList());
    save();
  }

  void discard() {
    draft = null;
    save();
  }

  /// Devuelve el mensaje a mostrar, o null si no hay series marcadas.
  String? finish() {
    final d = draft!;
    final ex = <ExLog>[];
    var pr = 0;
    for (final e in d.ex) {
      final ds = e.sets.where((s) => s.done && s.r > 0).map((s) => SetRec(s.w, s.r, true)).toList();
      if (ds.isEmpty) continue;
      final prev = logs.expand((w) => w.ex.where((x) => x.n == e.n)).expand((x) => x.sets).toList();
      if (prev.isNotEmpty &&
          ds.map((s) => e1(s.w, s.r)).reduce((a, b) => math.max(a, b)) > prev.map((s) => e1(s.w, s.r)).reduce((a, b) => math.max(a, b))) pr++;
      ex.add(ExLog(e.n, ds, e.note.trim()));
    }
    if (ex.isEmpty) return null;
    logs.add(Workout(d.id, d.name, d.date, ex));
    draft = null;
    save();
    return pr > 0 ? '¡Guardado! $pr récord${pr > 1 ? 's' : ''} nuevo${pr > 1 ? 's' : ''}' : 'Entrenamiento guardado';
  }
}

final store = Store();

// ───────────── App y tema ─────────────
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await store.load();
  runApp(const GymLogApp());
}

ThemeData buildTheme(bool dark) {
  final bg = dark ? const Color(0xFF0B0B0C) : const Color(0xFFF1F1F2);
  final card = dark ? const Color(0xFF171718) : Colors.white;
  final fg = dark ? const Color(0xFFF5F5F7) : const Color(0xFF111112);
  final inv = dark ? const Color(0xFF111112) : Colors.white;
  final inp = dark ? const Color(0xFF202022) : const Color(0xFFF0F0F1);
  final cs = ColorScheme(
    brightness: dark ? Brightness.dark : Brightness.light,
    primary: fg, onPrimary: inv, secondary: fg, onSecondary: inv,
    error: dark ? const Color(0xFFAEAEB2) : const Color(0xFF48484A), onError: inv,
    surface: card, onSurface: fg,
    outline: dark ? const Color(0xFF2C2C2E) : const Color(0xFFDCDCDE),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: cs,
    scaffoldBackgroundColor: bg,
    navigationBarTheme: NavigationBarThemeData(backgroundColor: card, indicatorColor: inp),
    inputDecorationTheme: InputDecorationTheme(
      filled: true, fillColor: inp, isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
    ),
  );
}

class GymLogApp extends StatelessWidget {
  const GymLogApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'GymLog',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(false),
        darkTheme: buildTheme(true),
        themeMode: ThemeMode.system,
        builder: (c, child) => GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
          child: child,
        ),
        home: const Home(),
      );
}

class Panel extends StatelessWidget {
  final Widget child;
  const Panel({super.key, required this.child});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: cs.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: cs.outline)),
      child: child,
    );
  }
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int tab = 0;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: IndexedStack(index: tab, children: const [TodayPage(), RoutinesPage(), HistoryPage(), RecordsPage(), StatsPage()]),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (i) => setState(() => tab = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.fitness_center), label: 'Hoy'),
            NavigationDestination(icon: Icon(Icons.checklist), label: 'Rutinas'),
            NavigationDestination(icon: Icon(Icons.calendar_month), label: 'Historial'),
            NavigationDestination(icon: Icon(Icons.emoji_events_outlined), label: 'Récords'),
            NavigationDestination(icon: Icon(Icons.bar_chart), label: 'Progreso'),
          ],
        ),
      );
}

Widget title(BuildContext c, String t, String sub) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(t, style: Theme.of(c).textTheme.headlineLarge?.copyWith(fontWeight: FontWeight.w700)),
      Text(sub, style: mu(c)),
      const SizedBox(height: 14),
    ]);

// ───────────── Hoy ─────────────
Widget chipSel(BuildContext c, String label, bool sel, VoidCallback f) {
  final cs = Theme.of(c).colorScheme;
  return ChoiceChip(
    label: Text(label),
    selected: sel,
    showCheckmark: false,
    selectedColor: cs.primary,
    labelStyle: TextStyle(color: sel ? cs.onPrimary : cs.onSurface),
    onSelected: (_) => f(),
  );
}

Widget routineCard(BuildContext context, Routine r, {bool big = false}) => Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
              child: Text(r.name,
                  style: big ? const TextStyle(fontWeight: FontWeight.w700, fontSize: 22) : bold)),
          FilledButton.icon(
              onPressed: () => store.startWorkout(r),
              icon: const Icon(Icons.play_arrow),
              label: const Text('Empezar')),
        ]),
        const SizedBox(height: 4),
        Text('${r.ex.length} ejercicios${dl(r)}', style: mu(context)),
        if (big) ...[const SizedBox(height: 6), Text(r.ex.join(' · '), style: mu(context))],
      ]),
    );

class WeekStrip extends StatelessWidget {
  const WeekStrip({super.key});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return Row(children: [
      for (var i = 0; i < 7; i++)
        Expanded(
          child: Builder(builder: (_) {
            final day = DateTime(now.year, now.month, now.day - (now.weekday - 1) + i);
            final isToday = day == today;
            final done = store.logs
                .any((w) => w.date.year == day.year && w.date.month == day.month && w.date.day == day.day);
            final planned = store.routines.any((r) => r.days.contains(i + 1));
            return Column(children: [
              Text(dayShort[i],
                  style: mu(context).copyWith(fontSize: 12, fontWeight: isToday ? FontWeight.w700 : FontWeight.w400)),
              const SizedBox(height: 6),
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isToday ? cs.primary : Colors.transparent,
                  border: Border.all(color: isToday ? cs.primary : cs.outline, width: 1.5),
                ),
                child: done
                    ? Icon(Icons.check, size: 18, color: isToday ? cs.onPrimary : cs.onSurface)
                    : Text('${day.day}',
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600, color: isToday ? cs.onPrimary : cs.onSurface)),
              ),
              const SizedBox(height: 5),
              Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                    shape: BoxShape.circle, color: planned ? cs.onSurface.withOpacity(.5) : Colors.transparent),
              ),
            ]);
          }),
        ),
    ]);
  }
}

class TodayPage extends StatelessWidget {
  const TodayPage({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (_, __) {
          if (store.draft != null) return WorkoutView();
          final now = DateTime.now();
          final td = now.weekday;
          final tod = store.routines.where((r) => r.days.contains(td)).toList();
          final rest = store.routines.where((r) => !tod.contains(r)).toList();
          final s = store.sorted;
          final lw = s.isEmpty ? null : s.last;
          final recs = store.records;
          final monday = DateTime(now.year, now.month, now.day - (td - 1));
          final doneDays =
              store.logs.where((w) => !w.date.isBefore(monday)).map((w) => '${w.date.month}-${w.date.day}').toSet().length;
          final plannedDays = <int>{for (final r in store.routines) ...r.days}.length;
          return ListView(padding: const EdgeInsets.all(16), children: [
            title(context, 'Hoy es ${dayFull[td - 1]}', 'Día $td de 7 de la semana · ${fd(now)}'),
            Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const WeekStrip(),
                const SizedBox(height: 10),
                Text(
                    plannedDays == 0
                        ? 'Asigna días a tus rutinas para ver tu semana.'
                        : 'Esta semana: $doneDays de $plannedDays días de entrenamiento',
                    style: mu(context)),
              ]),
            ),
            if (tod.isNotEmpty) ...[
              const Text('Hoy te toca', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 20)),
              const SizedBox(height: 8),
              for (final r in tod) routineCard(context, r, big: true),
            ] else
              Panel(
                child: Row(children: [
                  const Icon(Icons.self_improvement),
                  const SizedBox(width: 10),
                  Expanded(child: Text('Hoy no tienes rutina asignada: día de descanso.', style: mu(context))),
                ]),
              ),
            if (rest.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(tod.isEmpty ? 'Tus rutinas' : 'Otras rutinas', style: bold),
              const SizedBox(height: 8),
              for (final r in rest) routineCard(context, r),
            ],
            OutlinedButton.icon(
                onPressed: () => store.startWorkout(null),
                icon: const Icon(Icons.add),
                label: const Text('Entrenamiento libre')),
            if (recs.isNotEmpty) ...[
              const SizedBox(height: 20),
              Panel(
                child: Row(children: [
                  const Icon(Icons.emoji_events_outlined),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                        'Último récord: ${recs.first.ex} · ${fn(recs.first.w)}×${recs.first.r} (${fd(recs.first.date)})',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ]),
              ),
            ],
            if (lw != null) ...[
              const SizedBox(height: 8),
              const Text('Último entrenamiento', style: bold),
              const SizedBox(height: 8),
              Panel(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(lw.name, style: bold),
                  Text('${fd(lw.date)} · ${lw.volume.round()} kg de volumen', style: mu(context)),
                ]),
              ),
            ],
          ]);
        },
      );
}

class WorkoutView extends StatefulWidget {
  WorkoutView({super.key});
  @override
  State<WorkoutView> createState() => _WorkoutViewState();
}

class _WorkoutViewState extends State<WorkoutView> {
  final nx = TextEditingController();
  Timer? t;
  int rest = 0, total = 90;

  String fmt(int s) => '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';

  DateTime? end;

  void startRest() {
    t?.cancel();
    total = store.restSec;
    end = DateTime.now().add(Duration(seconds: total));
    setState(() => rest = total);
    t = Timer.periodic(const Duration(milliseconds: 500), (k) {
      final left = end!.difference(DateTime.now()).inMilliseconds;
      if (left <= 0) {
        k.cancel();
        HapticFeedback.heavyImpact();
        if (mounted) {
          setState(() => rest = 0);
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Descanso terminado')));
        }
      } else if (mounted) {
        final r = (left / 1000).ceil();
        if (r != rest) setState(() => rest = r);
      }
    });
  }

  void stopRest() {
    t?.cancel();
    setState(() => rest = 0);
  }

  void adjust(int d) {
    final left = end!.difference(DateTime.now()).inSeconds;
    if (left + d < 1) return;
    end = end!.add(Duration(seconds: d));
    setState(() {
      rest = left + d;
      total = math.max(total, rest);
    });
  }

  @override
  void dispose() {
    t?.cancel();
    nx.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = store.draft!;
    final cs = Theme.of(context).colorScheme;
    return Column(children: [
      if (rest > 0)
        Container(
          color: cs.surface,
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Column(children: [
            Row(children: [
              const Icon(Icons.timer_outlined),
              const SizedBox(width: 8),
              Text('Descanso ${fmt(rest)}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 22)),
              const Spacer(),
              TextButton(onPressed: () => adjust(-15), child: const Text('-15s')),
              TextButton(onPressed: () => adjust(15), child: const Text('+15s')),
              IconButton(onPressed: stopRest, icon: const Icon(Icons.close)),
            ]),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: LinearProgressIndicator(
                  value: rest / total, minHeight: 4, color: cs.primary, backgroundColor: cs.outline),
            ),
          ]),
        ),
      Expanded(
        child: ListView(padding: const EdgeInsets.all(16), children: [
          title(context, d.name, '${fd(d.date)}. Anota peso y repeticiones y marca cada serie con ✓.'),
          Panel(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Tiempo de descanso entre series', style: mu(context)),
              const SizedBox(height: 8),
              Wrap(spacing: 6, children: [
                for (final sec in [60, 90, 120, 180])
                  chipSel(context, fmt(sec), store.restSec == sec, () {
                    store.restSec = sec;
                    store.save();
                  }),
              ]),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                  onPressed: startRest, icon: const Icon(Icons.timer_outlined), label: const Text('Iniciar descanso')),
            ]),
          ),
          for (final e in d.ex) ExCard(key: ObjectKey(e), ex: e, onRest: () => startRest()),
          Panel(
            child: Row(children: [
              Expanded(child: TextField(controller: nx, decoration: const InputDecoration(hintText: 'Añadir ejercicio'))),
              const SizedBox(width: 8),
              FilledButton.icon(
                  onPressed: () {
                    final v = nx.text.trim();
                    if (v.isEmpty) return;
                    d.ex.add(store.mkEx(v));
                    nx.clear();
                    store.save();
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('Añadir')),
            ]),
          ),
          FilledButton.icon(
            onPressed: () {
              final m = store.finish();
              if (m == null) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('Marca al menos una serie con ✓')));
              } else {
                t?.cancel();
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
              }
            },
            icon: const Icon(Icons.check),
            label: const Text('Terminar y guardar'),
          ),
          TextButton(
              onPressed: () => confirm(context, '¿Descartar entrenamiento?', store.discard),
              child: const Text('Descartar entrenamiento')),
        ]),
      ),
    ]);
  }
}

class ExCard extends StatelessWidget {
  final ExLog ex;
  final VoidCallback onRest;
  const ExCard({super.key, required this.ex, required this.onRest});

  Widget num(String init, void Function(String) f, bool dec) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: TextFormField(
          initialValue: init,
          keyboardType: TextInputType.numberWithOptions(decimal: dec),
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
          onChanged: (v) {
            f(v);
            store.save(notify: false);
          },
        ),
      );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l = store.lastOf(ex.n);
    final h = mu(context);
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(ex.n, style: bold)),
          TextButton(
              onPressed: () => confirm(context, '¿Quitar ejercicio?', () {
                    store.draft!.ex.remove(ex);
                    store.save();
                  }),
              child: const Text('Quitar')),
        ]),
        if (l == null) Text('Primera vez con este ejercicio', style: h),
        const SizedBox(height: 8),
        TextFormField(
          initialValue: ex.note,
          minLines: 1,
          maxLines: 3,
          style: const TextStyle(fontSize: 14),
          decoration: const InputDecoration(hintText: 'Nota del ejercicio (ajuste de máquina, sensaciones…)'),
          onChanged: (v) {
            ex.note = v;
            store.save(notify: false);
          },
        ),
        const SizedBox(height: 10),
        Row(children: [
          SizedBox(width: 26, child: Text('Serie', style: h.copyWith(fontSize: 11), textAlign: TextAlign.center)),
          Expanded(flex: 11, child: Text('Anterior', style: h.copyWith(fontSize: 11), textAlign: TextAlign.center)),
          Expanded(flex: 10, child: Text('kg', style: h.copyWith(fontSize: 11), textAlign: TextAlign.center)),
          Expanded(flex: 10, child: Text('Reps', style: h.copyWith(fontSize: 11), textAlign: TextAlign.center)),
          const SizedBox(width: 76),
        ]),
        for (var j = 0; j < ex.sets.length; j++)
          Padding(
            key: ObjectKey(ex.sets[j]),
            padding: const EdgeInsets.only(top: 8),
            child: Builder(builder: (_) {
              final s = ex.sets[j];
              return Row(children: [
                SizedBox(width: 26, child: Text('${j + 1}', textAlign: TextAlign.center, style: h)),
                Expanded(
                  flex: 11,
                  child: Text(l != null && j < l.sets.length ? '${fn(l.sets[j].w)}×${l.sets[j].r}' : '–',
                      textAlign: TextAlign.center, style: h),
                ),
                Expanded(
                    flex: 10,
                    child: num(s.w == 0 ? '' : fn(s.w), (v) => s.w = double.tryParse(v.replaceAll(',', '.')) ?? 0, true)),
                Expanded(flex: 10, child: num(s.r == 0 ? '' : '${s.r}', (v) => s.r = int.tryParse(v) ?? 0, false)),
                SizedBox(
                  width: 40,
                  height: 40,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    style: IconButton.styleFrom(
                      backgroundColor: s.done ? cs.primary : cs.outline,
                      foregroundColor: s.done ? cs.onPrimary : cs.onSurface,
                    ),
                    onPressed: () {
                      s.done = !s.done;
                      store.save();
                      if (s.done) onRest();
                    },
                    icon: const Icon(Icons.check),
                  ),
                ),
                SizedBox(
                  width: 36,
                  height: 40,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    onPressed: () {
                      ex.sets.removeAt(j);
                      store.save();
                    },
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ),
              ]);
            }),
          ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () {
              final a = ex.sets;
              a.add(a.isEmpty ? SetRec(0, 0) : SetRec(a.last.w, a.last.r));
              store.save();
            },
            icon: const Icon(Icons.add),
            label: const Text('Serie'),
          ),
        ),
      ]),
    );
  }
}

// ───────────── Rutinas ─────────────
class RoutinesPage extends StatelessWidget {
  const RoutinesPage({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (_, __) {
          final td = DateTime.now().weekday;
          return ListView(padding: const EdgeInsets.all(16), children: [
            title(context, 'Rutinas', 'Organiza tu semana por días.'),
            Panel(
              child: Column(children: [
                for (var d = 1; d <= 7; d++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      Text(dayFull[d - 1] + (d == td ? ' · hoy' : ''),
                          style: d == td ? const TextStyle(fontWeight: FontWeight.w700) : mu(context)),
                      Flexible(
                        child: Text(
                          store.routines.where((r) => r.days.contains(d)).map((r) => r.name).join(' + ').isEmpty
                              ? 'Descanso'
                              : store.routines.where((r) => r.days.contains(d)).map((r) => r.name).join(' + '),
                          textAlign: TextAlign.right,
                          style: mu(context),
                        ),
                      ),
                    ]),
                  ),
              ]),
            ),
            const Text('Mis rutinas', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 20)),
            const SizedBox(height: 8),
            for (final r in store.routines)
              Panel(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text(r.name, style: bold)),
                    IconButton(
                        onPressed: () => Navigator.push(
                            context, MaterialPageRoute(builder: (_) => RoutineEditor(routine: r))),
                        icon: const Icon(Icons.edit_outlined)),
                    IconButton(
                        onPressed: () => confirm(context, '¿Borrar rutina?', () {
                              store.routines.remove(r);
                              store.save();
                            }),
                        icon: const Icon(Icons.delete_outline)),
                  ]),
                  Text(dl(r).isEmpty ? 'Sin día asignado' : dl(r).substring(3),
                      style: mu(context).copyWith(fontWeight: FontWeight.w600)),
                  Text(r.ex.join(' · '), style: mu(context)),
                ]),
              ),
            FilledButton.icon(
                onPressed: () =>
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const RoutineEditor())),
                icon: const Icon(Icons.add),
                label: const Text('Nueva rutina')),
          ]);
        },
      );
}

class RoutineEditor extends StatefulWidget {
  final Routine? routine;
  const RoutineEditor({super.key, this.routine});
  @override
  State<RoutineEditor> createState() => _RoutineEditorState();
}

class _RoutineEditorState extends State<RoutineEditor> {
  late final name = TextEditingController(text: widget.routine?.name ?? '');
  late final ex = TextEditingController(text: widget.routine?.ex.join('\n') ?? '');
  late final Set<int> days = {...?widget.routine?.days};

  void save() {
    final n = name.text.trim();
    final e = ex.text.split('\n').map((x) => x.trim()).where((x) => x.isNotEmpty).toList();
    if (n.isEmpty || e.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Pon un nombre y al menos un ejercicio')));
      return;
    }
    final r = widget.routine;
    if (r != null) {
      r.name = n;
      r.ex = e;
      r.days = days.toList();
    } else {
      store.routines.add(Routine(DateTime.now().millisecondsSinceEpoch.toString(), n, e, days.toList()));
    }
    store.save();
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.routine == null ? 'Nueva rutina' : 'Editar rutina')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(controller: name, decoration: const InputDecoration(hintText: 'Nombre (ej. Espalda y bíceps)')),
        const SizedBox(height: 10),
        TextField(
          controller: ex,
          minLines: 5,
          maxLines: 12,
          decoration: const InputDecoration(hintText: 'Un ejercicio por línea\nPress banca\nRemo con barra'),
        ),
        const SizedBox(height: 16),
        Text('Días de entrenamiento', style: mu(context)),
        const SizedBox(height: 6),
        Wrap(spacing: 6, children: [
          for (var d = 1; d <= 7; d++)
            FilterChip(
              label: Text(dayShort[d - 1]),
              selected: days.contains(d),
              selectedColor: cs.primary,
              checkmarkColor: cs.onPrimary,
              labelStyle: TextStyle(color: days.contains(d) ? cs.onPrimary : cs.onSurface),
              onSelected: (v) => setState(() {
                if (v) {
                  days.add(d);
                } else {
                  days.remove(d);
                }
              }),
            ),
        ]),
        const SizedBox(height: 20),
        FilledButton(onPressed: save, child: const Text('Guardar')),
      ]),
    );
  }
}

// ───────────── Historial ─────────────
class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (_, __) {
          final L = store.sorted.reversed.toList();
          return ListView(padding: const EdgeInsets.all(16), children: [
            title(context, 'Historial', '${L.length} entrenamiento${L.length == 1 ? '' : 's'} guardado${L.length == 1 ? '' : 's'}.'),
            if (L.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Todavía no hay entrenamientos. Termina uno en Hoy y aparecerá aquí.',
                    textAlign: TextAlign.center, style: mu(context)),
              ),
            for (final w in L)
              Panel(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(w.name, style: bold),
                        Text('${fd(w.date)} · ${w.volume.round()} kg de volumen', style: mu(context)),
                      ]),
                    ),
                    IconButton(
                        onPressed: () => confirm(context, '¿Borrar entrenamiento?', () {
                              store.logs.removeWhere((x) => x.id == w.id);
                              store.save();
                            }),
                        icon: const Icon(Icons.delete_outline)),
                  ]),
                  for (final e in w.ex)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(e.n, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                        Text(e.sets.map((s) => '${fn(s.w)}×${s.r}').join(' · '), style: mu(context)),
                        if (e.note.isNotEmpty)
                          Text(e.note, style: mu(context).copyWith(fontStyle: FontStyle.italic)),
                      ]),
                    ),
                ]),
              ),
          ]);
        },
      );
}

// ───────────── Récords ─────────────
Widget statTile(BuildContext c, IconData i, String big, String small) => Expanded(
      child: Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(i, color: Theme.of(c).colorScheme.onSurface.withOpacity(.6)),
          const SizedBox(height: 8),
          Text(big, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w700)),
          Text(small, style: mu(c)),
        ]),
      ),
    );

class RecordsPage extends StatelessWidget {
  const RecordsPage({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (_, __) {
          final cs = Theme.of(context).colorScheme;
          final recs = store.records;
          final now = DateTime.now();
          final month = recs.where((r) => now.difference(r.date).inDays < 30).length;
          final best = <String, SetRec>{};
          for (final w in store.logs) {
            for (final e in w.ex) {
              for (final x in e.sets) {
                final b = best[e.n];
                if (b == null || e1(x.w, x.r) > e1(b.w, b.r)) best[e.n] = x;
              }
            }
          }
          final names = best.keys.toList()..sort();
          return ListView(padding: const EdgeInsets.all(16), children: [
            title(context, 'Récords', 'Tus mejores marcas y cada vez que superas una.'),
            Row(children: [
              statTile(context, Icons.emoji_events_outlined, '$month', 'récords en 30 días'),
              const SizedBox(width: 10),
              statTile(context, Icons.military_tech_outlined, '${recs.length}', 'récords en total'),
            ]),
            const Text('Nuevos récords', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 20)),
            const SizedBox(height: 8),
            if (recs.isEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                    'Aún no hay récords. Aparecen cuando superas tu mejor marca estimada en un ejercicio que ya habías registrado.',
                    textAlign: TextAlign.center,
                    style: mu(context)),
              ),
            for (final r in recs.take(20))
              Panel(
                child: Row(children: [
                  const Icon(Icons.emoji_events_outlined),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Flexible(child: Text(r.ex, style: bold)),
                        if (now.difference(r.date).inDays < 7) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(6)),
                            child: Text('NUEVO',
                                style: TextStyle(color: cs.onPrimary, fontSize: 11, fontWeight: FontWeight.w700)),
                          ),
                        ],
                      ]),
                      Text('${fn(r.w)} kg × ${r.r} reps · 1RM est. ${fn(r.e)} kg', style: mu(context)),
                      Text('${fd(r.date)} · +${fn(r.gain)} kg sobre tu marca anterior', style: mu(context)),
                    ]),
                  ),
                ]),
              ),
            if (names.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text('Mejores marcas por ejercicio', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 20)),
              const SizedBox(height: 8),
              Panel(
                child: Column(children: [
                  for (final n in names)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(children: [
                        Expanded(child: Text(n)),
                        Text('${fn(best[n]!.w)} kg × ${best[n]!.r}', style: const TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(width: 10),
                        Text('1RM ${fn(e1(best[n]!.w, best[n]!.r))}', style: mu(context)),
                      ]),
                    ),
                ]),
              ),
            ],
          ]);
        },
      );
}

// ───────────── Progreso (estadísticas) ─────────────
class StatsPage extends StatefulWidget {
  const StatsPage({super.key});
  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  String sel = '';
  int metric = 0; // 0 = 1RM estimado, 1 = peso máximo, 2 = volumen

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (_, __) {
          final cs = Theme.of(context).colorScheme;
          final L = store.sorted;
          if (L.isEmpty) {
            return ListView(padding: const EdgeInsets.all(16), children: [
              title(context, 'Progreso', 'Tu avance de un vistazo.'),
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Aquí verás tu progreso en cuanto guardes tu primer entrenamiento.',
                    textAlign: TextAlign.center, style: mu(context)),
              ),
            ]);
          }
          final now = DateTime.now();
          int age(Workout w) => now.difference(w.date).inDays;
          final names = L.expand((w) => w.ex.map((e) => e.n)).toSet().toList()..sort();
          if (!names.contains(sel)) sel = names.first;
          final wk = L.where((w) => age(w) < 7).length;
          final tv = L.fold(0.0, (a, w) => a + w.volume);
          final bars = List.generate(8, (i) => L.where((w) => age(w) >= 7 * (7 - i) && age(w) < 7 * (8 - i)).length);
          final withEx = L.where((w) => w.ex.any((e) => e.n == sel)).toList();
          final ys = withEx.map((w) {
            final ss = w.ex.firstWhere((e) => e.n == sel).sets;
            if (metric == 1) return ss.map((s) => s.w).reduce((a, b) => math.max(a, b));
            if (metric == 2) return ss.fold(0.0, (a, s) => a + s.w * s.r);
            return ss.map((s) => e1(s.w, s.r)).reduce((a, b) => math.max(a, b));
          }).toList();
          final all = L.expand((w) => w.ex.where((e) => e.n == sel)).expand((e) => e.sets).toList();
          final pw = all.map((s) => s.w).reduce((a, b) => math.max(a, b));
          final best = all.map((s) => e1(s.w, s.r)).reduce((a, b) => math.max(a, b));
          const caps = ['1RM estimado por día (fórmula de Epley)', 'Peso máximo por día', 'Volumen por día (peso × repeticiones)'];
          final change = ys.length < 2 ? null : ys.last - ys.first;
          return ListView(padding: const EdgeInsets.all(16), children: [
            title(context, 'Progreso', 'Tu avance de un vistazo.'),
            Row(children: [
              statTile(context, Icons.fitness_center, '${L.length}', 'entrenamientos'),
              const SizedBox(width: 10),
              statTile(context, Icons.local_fire_department_outlined, '$wk', 'esta semana'),
            ]),
            Row(children: [
              statTile(context, Icons.scale_outlined, tv >= 1000 ? '${fn(tv / 1000)}k' : '${tv.round()}', 'volumen total (kg)'),
              const SizedBox(width: 10),
              statTile(context, Icons.checklist, '${names.length}', 'ejercicios distintos'),
            ]),
            Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Entrenamientos por semana', style: bold),
                const SizedBox(height: 8),
                SizedBox(
                  height: 110,
                  width: double.infinity,
                  child: CustomPaint(
                      painter: BarsPainter(bars, cs.primary, cs.onSurface.withOpacity(.3), cs.onSurface.withOpacity(.6))),
                ),
              ]),
            ),
            Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Progreso por ejercicio', style: bold),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: sel,
                  items: names.map((n) => DropdownMenuItem(value: n, child: Text(n))).toList(),
                  onChanged: (v) => setState(() => sel = v ?? sel),
                ),
                const SizedBox(height: 10),
                Row(children: [
                  statTile(context, Icons.scale_outlined, fn(pw), 'peso máximo (kg)'),
                  const SizedBox(width: 10),
                  statTile(context, Icons.bar_chart, fn(best), '1RM estimado (kg)'),
                ]),
                Wrap(spacing: 6, children: [
                  chipSel(context, '1RM', metric == 0, () => setState(() => metric = 0)),
                  chipSel(context, 'Peso máximo', metric == 1, () => setState(() => metric = 1)),
                  chipSel(context, 'Volumen', metric == 2, () => setState(() => metric = 2)),
                ]),
                const SizedBox(height: 10),
                Text(caps[metric], style: mu(context)),
                if (change != null)
                  Text('Cambio desde el primer registro: ${change >= 0 ? '+' : ''}${fn(change)}',
                      style: mu(context).copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                if (ys.length < 2)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text('Registra este ejercicio en al menos 2 días para ver la gráfica.',
                        textAlign: TextAlign.center, style: mu(context)),
                  )
                else
                  SizedBox(
                    height: 170,
                    width: double.infinity,
                    child: CustomPaint(
                      painter: LinePainter(ys, fd(withEx.first.date), fd(withEx.last.date), cs.primary,
                          cs.onSurface.withOpacity(.6)),
                    ),
                  ),
              ]),
            ),
          ]);
        },
      );
}

void _txt(Canvas c, String s, Offset o, Color col, {TextAlign align = TextAlign.center}) {
  final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: col, fontSize: 10)), textDirection: TextDirection.ltr)
    ..layout();
  final dx = align == TextAlign.center ? o.dx - tp.width / 2 : (align == TextAlign.right ? o.dx - tp.width : o.dx);
  tp.paint(c, Offset(dx, o.dy));
}

class BarsPainter extends CustomPainter {
  final List<int> v;
  final Color on, off, tx;
  BarsPainter(this.v, this.on, this.off, this.tx);
  @override
  void paint(Canvas c, Size s) {
    final mx = math.max(1, v.reduce((a, b) => math.max(a, b)));
    final bw = s.width / v.length;
    const top = 16.0;
    final ch = s.height - 34;
    for (var i = 0; i < v.length; i++) {
      final h = ch * v[i] / mx;
      final last = i == v.length - 1;
      c.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(i * bw + bw * .15, top + ch - h, bw * .7, h), const Radius.circular(5)),
        Paint()..color = last ? on : off,
      );
      _txt(c, '${v[i]}', Offset(i * bw + bw / 2, top + ch - h - 14), tx);
      _txt(c, last ? 'ahora' : '-${v.length - 1 - i}s', Offset(i * bw + bw / 2, s.height - 14), tx);
    }
  }

  @override
  bool shouldRepaint(covariant BarsPainter o) => true;
}

class LinePainter extends CustomPainter {
  final List<double> ys;
  final String a, b;
  final Color col, tx;
  LinePainter(this.ys, this.a, this.b, this.col, this.tx);
  @override
  void paint(Canvas c, Size s) {
    const l = 34.0, r = 12.0, t = 14.0, bt = 24.0;
    final mn = ys.reduce((a, b) => math.min(a, b)), mx = ys.reduce((a, b) => math.max(a, b));
    final rg = (mx - mn) == 0 ? 1.0 : mx - mn;
    Offset p(int i) => Offset(l + i * (s.width - l - r) / (ys.length - 1),
        s.height - bt - (ys[i] - mn) / rg * (s.height - t - bt));
    final path = Path()..moveTo(p(0).dx, p(0).dy);
    for (var i = 1; i < ys.length; i++) {
      path.lineTo(p(i).dx, p(i).dy);
    }
    c.drawPath(path, Paint()
      ..color = col
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeJoin = StrokeJoin.round);
    for (var i = 0; i < ys.length; i++) {
      c.drawCircle(p(i), 4, Paint()..color = col);
    }
    _txt(c, fn(mx), const Offset(0, 2), tx, align: TextAlign.left);
    _txt(c, fn(mn), Offset(0, s.height - bt - 6), tx, align: TextAlign.left);
    _txt(c, a, Offset(l, s.height - 14), tx, align: TextAlign.left);
    _txt(c, b, Offset(s.width - r, s.height - 14), tx, align: TextAlign.right);
  }

  @override
  bool shouldRepaint(covariant LinePainter o) => true;
}
