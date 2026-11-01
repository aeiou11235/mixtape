<?php
// Mixtape share links on ordinary web space. The app encrypts each tape before it uploads it;
// only the link holds the key (after the #, which browsers never send), so this server stores
// nothing it could read. Tapes are kept in t/ for 30 days. KEY must match the one built into the app.
const KEY = 'REPLACE_WITH_KEY';
const DAYS = 30;
const MAX = 26 * 1024 * 1024;

header('Content-Type: application/json');
if ($_SERVER['REQUEST_METHOD'] !== 'POST' || !hash_equals(KEY, $_SERVER['HTTP_X_MIXTAPE_KEY'] ?? '')) {
    http_response_code(403);
    exit('{"error":"Not allowed."}');
}
$data = file_get_contents('php://input', false, null, 0, MAX + 1);
if ($data === false || strlen($data) < 1000 || strlen($data) > MAX) {
    http_response_code(400);
    exit('{"error":"That tape is empty or too big."}');
}
$dir = __DIR__ . '/t';
if (!is_dir($dir)) mkdir($dir, 0755);
// Old tapes run out.
foreach (glob("$dir/*.bin") as $f) {
    if (filemtime($f) < time() - DAYS * 86400) unlink($f);
}
// Ten letters and digits: far too many to guess.
$abc = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
$id = '';
for ($i = 0; $i < 10; $i++) $id .= $abc[random_int(0, strlen($abc) - 1)];
file_put_contents("$dir/$id.bin", $data);
echo json_encode(['id' => $id, 'days' => DAYS]);
