<?php
// Mixtape share links on ordinary web space. The app encrypts each tape before it uploads it;
// only the link holds the key (after the #, which browsers never send), so this server stores
// nothing it could read. Tapes are kept in t/ for 30 days. KEY must match the one built into the app.
//
// A tape comes in parts of a few MB, each as Base64 text: web space limits how big one upload may
// be, and firewalls tend to turn away raw binary. POST ?part=0&of=N starts a tape and answers its
// id; the following parts add &id=…; the last one finishes it.
const KEY = 'REPLACE_WITH_KEY';
const DAYS = 30;
const MAX = 26 * 1024 * 1024;     // a whole tape
const PART = 6 * 1024 * 1024;     // one part, as it arrives

header('Content-Type: application/json');
function fail($code, $why) { http_response_code($code); exit(json_encode(['error' => $why])); }

if ($_SERVER['REQUEST_METHOD'] !== 'POST' || !hash_equals(KEY, $_SERVER['HTTP_X_MIXTAPE_KEY'] ?? '')) fail(403, 'Not allowed.');
$part = (int)($_GET['part'] ?? 0);
$of = (int)($_GET['of'] ?? 1);
if ($of < 1 || $of > 20 || $part < 0 || $part >= $of) fail(400, 'Bad part.');

$text = file_get_contents('php://input', false, null, 0, PART + 1);
$data = ($text === false || strlen($text) > PART) ? false : base64_decode($text, true);
if ($data === false || $data === '') fail(400, 'That part is empty or too big.');

$dir = __DIR__ . '/t';
if (!is_dir($dir)) mkdir($dir, 0755);

if ($part === 0) {
    // Old tapes run out; tapes that never finished are cleared after a day.
    foreach (glob("$dir/*.bin") as $f) if (filemtime($f) < time() - DAYS * 86400) unlink($f);
    foreach (glob("$dir/*.part") as $f) if (filemtime($f) < time() - 86400) unlink($f);
    // Ten letters and digits: far too many to guess.
    $abc = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
    $id = '';
    for ($i = 0; $i < 10; $i++) $id .= $abc[random_int(0, strlen($abc) - 1)];
} else {
    $id = $_GET['id'] ?? '';
    if (!preg_match('/^[A-Za-z0-9]{10}$/', $id) || !is_file("$dir/$id.part")) fail(400, 'Unknown tape.');
}

$file = "$dir/$id.part";
file_put_contents($file, $data, FILE_APPEND);
clearstatcache();
if (filesize($file) > MAX) { unlink($file); fail(400, 'That tape is too big.'); }
if ($part === $of - 1) rename($file, "$dir/$id.bin");
echo json_encode(['id' => $id, 'days' => DAYS]);
