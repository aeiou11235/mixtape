<?php
// Counts, day by day, how many tapes were shared and how many were opened. Numbers only: no
// addresses, no names, nothing about the tapes. They are kept in counts.php, which starts with
// an exit, so nobody can read it from outside; stats.php shows them.
const COUNTS = __DIR__ . '/counts.php';

function counts() {
    $text = @file_get_contents(COUNTS);
    $nl = $text === false ? false : strpos($text, "\n");
    return $nl === false ? [] : (json_decode(substr($text, $nl + 1), true) ?: []);
}

// $what: 'shared' (from the app everyone has), 'kept' (from the owner's Mac) or 'opened'.
function count_up($what) {
    $h = @fopen(COUNTS, 'c+');
    if (!$h) return;
    flock($h, LOCK_EX);
    $text = stream_get_contents($h);
    $nl = strpos($text, "\n");
    $data = $nl === false ? [] : (json_decode(substr($text, $nl + 1), true) ?: []);
    $day = gmdate('Y-m-d');
    $data[$day][$what] = ($data[$day][$what] ?? 0) + 1;
    ftruncate($h, 0);
    rewind($h);
    fwrite($h, "<?php exit; ?>\n" . json_encode($data));
    fflush($h);
    flock($h, LOCK_UN);
    fclose($h);
}
