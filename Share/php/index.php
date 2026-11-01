<?php
// The share page. Messengers like Signal and WhatsApp read the page for a preview, but never the
// part after the # – so the link also names its tape as ?t=…, and the preview shows its cassette.
$id = preg_match('/^[A-Za-z0-9]{10}$/', $_GET['t'] ?? '') ? $_GET['t'] : '';
$base = 'https://' . $_SERVER['HTTP_HOST'] . rtrim(dirname($_SERVER['SCRIPT_NAME']), '/');
$image = ($id && is_file(__DIR__ . "/t/$id.png")) ? "$base/t/$id.png" : '';
?><!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Mixtape</title>
<meta property="og:type" content="website">
<meta property="og:site_name" content="Mixtape">
<meta property="og:title" content="Someone made you a mixtape">
<meta property="og:description" content="Tap to play – made with Mixtape for Mac.">
<?php if ($image): ?>
<meta property="og:image" content="<?= htmlspecialchars($image) ?>">
<meta property="og:image:width" content="690">
<meta property="og:image:height" content="462">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:image" content="<?= htmlspecialchars($image) ?>">
<?php endif; ?>
<style>
  html, body { margin: 0; height: 100%; background: linear-gradient(#1a0638, #c42583 60%, #ffb347); color: #fff;
    font: 17px/1.45 -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif; }
  main { min-height: 100%; display: flex; align-items: center; justify-content: center; text-align: center; padding: 24px; box-sizing: border-box; }
</style>
</head>
<body>
<main><p id="msg">Unwrapping your mixtape …</p></main>
<script>
// The link is …/#<tape>.<key>. The part after # never leaves this browser: the tape is fetched
// encrypted and unlocked here with AES-GCM, then it takes over the page – played by the newest
// player.html on this server, so links sent before a fix get it too. Only the tape's own data is
// taken from it; if that can't be found, the tape plays with the player it came with.
async function newest(html) {
  try {
    const res = await fetch('player.html', { cache: 'no-cache' });
    if (!res.ok) return html;
    const player = await res.text();
    const line = name => { const m = html.match(new RegExp('^const ' + name + ' = (.*);$', 'm')); return m ? m[1] : null; };
    const tape = line('TAPE'), audio = line('AUDIO');
    if (!tape || !audio || !player.includes('__TAPE_JSON__')) return html;
    const title = (html.match(/<title>([^<]*)<\/title>/) || [])[1] || 'Mixtape';
    const icon = (html.match(/<link rel="icon" href="([^"]*)"/) || [])[1] || '';
    const fill = (s, key, value) => s.split(key).join(value);
    let page = fill(player, '__SKIN_JSON__', line('SKIN') || 'null');
    page = fill(page, '__TITLE__', title);
    page = fill(page, '__ICON__', icon);
    page = fill(page, '__TAPE_JSON__', tape);
    return fill(page, '__AUDIO_JSON__', audio);
  } catch (e) {
    return html;
  }
}
(async () => {
  const say = t => { document.getElementById('msg').textContent = t; };
  const [id, k] = location.hash.slice(1).split('.');
  if (!/^[A-Za-z0-9]{10}$/.test(id || '') || !k) return say('This link is incomplete – ask for it again.');
  try {
    const res = await fetch(`t/${id}.bin`, { cache: 'no-store' });
    if (!res.ok) return say('This tape has run out – ask for a new link.');
    const box = new Uint8Array(await res.arrayBuffer());
    const raw = Uint8Array.from(atob(k.replace(/-/g, '+').replace(/_/g, '/')), c => c.charCodeAt(0));
    const key = await crypto.subtle.importKey('raw', raw, 'AES-GCM', false, ['decrypt']);
    const plain = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: box.slice(0, 12) }, key, box.slice(12));
    const html = await newest(new TextDecoder().decode(plain));
    document.open();
    document.write(html);
    document.close();
  } catch (e) {
    say('This tape could not be unlocked – the link may be cut off.');
  }
})();
</script>
</body>
</html>
