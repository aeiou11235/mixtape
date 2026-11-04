<?php
// Mixtape share links on ordinary web space. The app encrypts each tape before it uploads it;
// only the link holds the key (after the #, which browsers never send), so this server stores
// nothing it could read.
//
// A tape comes in parts of about 1 MB, each as Base64 text: web space limits how big one upload
// may be, and firewalls tend to turn away raw binary. POST ?part=0&of=N starts a tape and answers
// its id; the following parts add &id=…; the last one finishes it. POST ?image=1&id=… then adds a
// small picture of the cassette (not encrypted), for the link in an email.
//
// Which key the app sends decides how long its tapes stay: the public app's for DAYS days,
// the owner's for good.
const PUBLIC_KEY = 'REPLACE_WITH_PUBLIC_KEY';
const OWNER_KEY = 'REPLACE_WITH_OWNER_KEY';
const DAYS = 7;
const MAX = 26 * 1024 * 1024;     // a whole tape
const PART = 6 * 1024 * 1024;     // one part, as it arrives
const IMAGE = 1024 * 1024;        // the picture

require __DIR__ . '/count.php';
header('Content-Type: application/json');
function fail($code, $why) { http_response_code($code); exit(json_encode(['error' => $why])); }

$sent = $_SERVER['HTTP_X_MIXTAPE_KEY'] ?? '';
if (hash_equals(OWNER_KEY, $sent)) $days = 0;
elseif (hash_equals(PUBLIC_KEY, $sent)) $days = DAYS;
else fail(403, 'Not allowed.');
if ($_SERVER['REQUEST_METHOD'] !== 'POST') fail(405, 'POST only.');

$dir = __DIR__ . '/t';
if (!is_dir($dir)) mkdir($dir, 0755);
$text = file_get_contents('php://input', false, null, 0, PART + 1);
$data = ($text === false || strlen($text) > PART) ? false : base64_decode($text, true);
if ($data === false || $data === '') fail(400, 'That part is empty or too big.');

if (isset($_GET['image'])) {
    $id = $_GET['id'] ?? '';
    if (!preg_match('/^[A-Za-z0-9]{10}$/', $id) || !is_file("$dir/$id.bin")) fail(400, 'Unknown tape.');
    if (strlen($data) > IMAGE || substr($data, 0, 8) !== "\x89PNG\r\n\x1a\n") fail(400, 'Not a picture.');
    file_put_contents("$dir/$id.png", $data);
    exit(json_encode(['id' => $id, 'days' => $days]));
}

$part = (int)($_GET['part'] ?? 0);
$of = (int)($_GET['of'] ?? 1);
if ($of < 1 || $of > 40 || $part < 0 || $part >= $of) fail(400, 'Bad part.');

if ($part === 0) {
    // Tapes run out after DAYS days unless they are kept; tapes that never finished go after a day.
    foreach (glob("$dir/*.bin") as $f) {
        $base = substr($f, 0, -4);
        if (!is_file("$base.keep") && filemtime($f) < time() - DAYS * 86400) {
            unlink($f);
            if (is_file("$base.png")) unlink("$base.png");
        }
    }
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
if ($part === $of - 1) {
    rename($file, "$dir/$id.bin");
    if ($days === 0) touch("$dir/$id.keep");
    count_up($days === 0 ? 'kept' : 'shared');
}
echo json_encode(['id' => $id, 'days' => $days]);
