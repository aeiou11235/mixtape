<?php
// How much Mixtape is used: tapes shared and opened, per day and month. Only with the key in the
// link (stats.php?k=…), so the numbers stay the owner's.
const STATS_KEY = 'REPLACE_WITH_STATS_KEY';
if (!hash_equals(STATS_KEY, $_GET['k'] ?? '')) { http_response_code(404); exit; }
require __DIR__ . '/count.php';
header('Cache-Control: no-store');

$days = counts();
krsort($days);
$months = [];
$all = ['shared' => 0, 'kept' => 0, 'opened' => 0];
foreach ($days as $day => $n) {
    foreach ($all as $k => $_) {
        $months[substr($day, 0, 7)][$k] = ($months[substr($day, 0, 7)][$k] ?? 0) + ($n[$k] ?? 0);
        $all[$k] += $n[$k] ?? 0;
    }
}
$live = count(glob(__DIR__ . '/t/*.bin'));
$keep = count(glob(__DIR__ . '/t/*.keep'));
function row($when, $n) {
    return '<tr><td>' . htmlspecialchars($when) . '</td><td>' . ($n['shared'] ?? 0) . '</td><td>' . ($n['kept'] ?? 0)
        . '</td><td>' . ($n['opened'] ?? 0) . '</td></tr>';
}
?><!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>Mixtape – Zahlen</title>
<style>
  body { margin: 0; padding: 32px 16px; background: #14052e; color: #fff7ee; font: 16px/1.5 -apple-system, "Helvetica Neue", sans-serif; }
  main { max-width: 560px; margin: 0 auto; }
  h1 { font: italic 900 40px/1 "Futura", "Avenir Next", sans-serif; margin: 0 0 8px; }
  h2 { font-size: 17px; color: #ffd23f; margin: 40px 0 8px; }
  p { color: rgba(255,247,238,.78); margin: 0 0 8px; }
  table { width: 100%; border-collapse: collapse; font-variant-numeric: tabular-nums; }
  th, td { text-align: right; padding: 6px 8px; border-bottom: 1px solid rgba(255,247,238,.15); }
  th:first-child, td:first-child { text-align: left; }
  th { font-weight: 600; color: rgba(255,247,238,.78); }
  .big { font-size: 22px; color: #fff7ee; }
</style>
</head>
<body>
<main>
<h1>Mixtape</h1>
<p class="big">Insgesamt <?= $all['shared'] ?> Tapes von anderen geteilt, <?= $all['kept'] ?> von dir, <?= $all['opened'] ?>-mal geöffnet.</p>
<p>Gerade liegen <?= $live ?> Tapes auf dem Server, <?= $keep ?> davon deine, die nicht ablaufen.</p>
<p>Gezählt wird seit dem Einbau des Zählers. „Geöffnet“ heißt: ein Tape wurde im Browser entschlüsselt, Neuladen zählt mit.</p>
<h2>Nach Monat</h2>
<table><tr><th></th><th>geteilt</th><th>von dir</th><th>geöffnet</th></tr>
<?php foreach ($months as $m => $n) echo row($m, $n); ?>
</table>
<h2>Nach Tag</h2>
<table><tr><th></th><th>geteilt</th><th>von dir</th><th>geöffnet</th></tr>
<?php foreach (array_slice($days, 0, 60, true) as $d => $n) echo row($d, $n); ?>
</table>
</main>
</body>
</html>
