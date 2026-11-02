<?php
// mixtape.toyko.online: the home of Mixtape, and the page every shared tape opens on.
// A tape link is …/?t=<tape>#<tape>.<key>. Messengers like Signal and WhatsApp read the page for a
// preview but never the part after the #, so ?t= names the tape and the preview shows its cassette.
$id = preg_match('/^[A-Za-z0-9]{10}$/', $_GET['t'] ?? '') ? $_GET['t'] : '';
$base = 'https://' . $_SERVER['HTTP_HOST'] . rtrim(dirname($_SERVER['SCRIPT_NAME']), '/');
// Links from before they named their tape get a picture of a cassette all the same.
$image = ($id && is_file(__DIR__ . "/t/$id.png")) ? "$base/t/$id.png" : (is_file(__DIR__ . '/preview.png') ? "$base/preview.png" : '');
$title = $id ? 'Someone made you a mixtape' : 'Mixtape – a cassette for your Mac';
$about = $id ? 'Tap to play – made with Mixtape for Mac.' : 'Tape anything your Mac plays, punch the title onto label tape, send it to a friend. Free.';
?><!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Mixtape</title>
<meta name="description" content="<?= htmlspecialchars($about) ?>">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Mixtape">
<meta property="og:title" content="<?= htmlspecialchars($title) ?>">
<meta property="og:description" content="<?= htmlspecialchars($about) ?>">
<?php if ($image): ?>
<meta property="og:image" content="<?= htmlspecialchars($image) ?>">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:image" content="<?= htmlspecialchars($image) ?>">
<?php endif; ?>
<style>
  :root { --ink: #fff7ee; --dim: rgba(255,247,238,.78); --neon: #ff3fa4; --cyan: #33e1ff; --sun: #ffd23f; --night: #14052e; }
  * { box-sizing: border-box; }
  html { background: var(--night); }
  body { margin: 0; color: var(--ink); font: 17px/1.55 -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif;
    background: linear-gradient(180deg, #14052e 0%, #2c0a5e 18%, #6a1a8c 36%, #c42583 56%, #ff5f62 74%, #ffb347 92%, #ffd36b 100%); min-height: 100vh; }
  a { color: inherit; }
  .wrap { width: min(1040px, 100%); margin: 0 auto; padding: 0 16px; }

  /* The unwrapping note while a shared tape loads. */
  #unwrap { display: none; min-height: 100vh; flex-direction: column; align-items: center; justify-content: center; text-align: center; padding: 24px; }
  /* How much of the tape has arrived. Without a known size the fill runs back and forth. */
  #bar { width: min(320px, 80vw); height: 10px; margin-top: 16px; border-radius: 5px; overflow: hidden;
    background: rgba(255,247,238,.18); box-shadow: inset 0 0 0 1px rgba(255,247,238,.35); }
  #bar i { display: block; height: 100%; width: 0; border-radius: 5px; transition: width .2s;
    background: linear-gradient(90deg, #ff5f62, #ffb347, #ffd36b, #5fd3a0, #4fa8ff, #b06bff); }
  #bar.unknown i { width: 30%; transition: none; animation: sweep 1.2s ease-in-out infinite alternate; }
  #bar.gone { visibility: hidden; }
  @keyframes sweep { from { transform: translateX(0); } to { transform: translateX(233%); } }
  body.tape #unwrap { display: flex; }
  body.tape #home { display: none; }

  header.wrap { padding: 104px 16px 8px; text-align: center; }
  /* A few stars in the night sky above the sunset, fading out towards it. */
  #home { position: relative; }
  #home::before { content: ""; position: absolute; left: 0; right: 0; top: 0; height: 560px; pointer-events: none;
    background: radial-gradient(circle at 83.2% 57.5%, rgba(255,247,238,0.56) 0.6px, transparent 1.4px),
    radial-gradient(circle at 47.5% 36.4%, rgba(255,247,238,0.68) 1.3px, transparent 2.1px),
    radial-gradient(circle at 31.9% 8.8%, rgba(255,247,238,0.43) 1.3px, transparent 2.1px),
    radial-gradient(circle at 50.6% 58.5%, rgba(255,247,238,0.62) 1px, transparent 1.8px),
    radial-gradient(circle at 77.5% 83.5%, rgba(255,247,238,0.53) 1.3px, transparent 2.1px),
    radial-gradient(circle at 4.3% 58.7%, rgba(255,247,238,0.65) 0.6px, transparent 1.4px),
    radial-gradient(circle at 86.9% 31.9%, rgba(255,247,238,0.39) 1.3px, transparent 2.1px),
    radial-gradient(circle at 60.5% 48.7%, rgba(255,247,238,0.82) 1px, transparent 1.8px),
    radial-gradient(circle at 3.2% 94.9%, rgba(255,247,238,0.36) 0.6px, transparent 1.4px),
    radial-gradient(circle at 97.3% 88.6%, rgba(255,247,238,0.45) 1.3px, transparent 2.1px),
    radial-gradient(circle at 10.3% 29.0%, rgba(255,247,238,0.67) 1.3px, transparent 2.1px),
    radial-gradient(circle at 57.6% 58.4%, rgba(255,247,238,0.47) 0.8px, transparent 1.6px),
    radial-gradient(circle at 90.2% 87.6%, rgba(255,247,238,0.41) 0.8px, transparent 1.6px),
    radial-gradient(circle at 59.6% 82.0%, rgba(255,247,238,0.63) 1px, transparent 1.8px),
    radial-gradient(circle at 18.1% 51.9%, rgba(255,247,238,0.79) 0.6px, transparent 1.4px),
    radial-gradient(circle at 36.9% 29.7%, rgba(255,247,238,0.53) 1.3px, transparent 2.1px),
    radial-gradient(circle at 87.2% 92.2%, rgba(255,247,238,0.7) 1px, transparent 1.8px),
    radial-gradient(circle at 24.7% 73.6%, rgba(255,247,238,0.74) 1px, transparent 1.8px),
    radial-gradient(circle at 11.4% 57.8%, rgba(255,247,238,0.5) 1px, transparent 1.8px),
    radial-gradient(circle at 36.6% 79.7%, rgba(255,247,238,0.43) 1.3px, transparent 2.1px),
    radial-gradient(circle at 64.5% 75.7%, rgba(255,247,238,0.72) 1px, transparent 1.8px),
    radial-gradient(circle at 27.2% 54.2%, rgba(255,247,238,0.44) 0.8px, transparent 1.6px),
    radial-gradient(circle at 50.2% 49.3%, rgba(255,247,238,0.72) 1.3px, transparent 2.1px),
    radial-gradient(circle at 30.9% 1.4%, rgba(255,247,238,0.72) 1px, transparent 1.8px),
    radial-gradient(circle at 61.2% 73.2%, rgba(255,247,238,0.36) 0.8px, transparent 1.6px),
    radial-gradient(circle at 59.7% 11.8%, rgba(255,247,238,0.52) 1px, transparent 1.8px),
    radial-gradient(circle at 1.6% 58.6%, rgba(255,247,238,0.47) 0.8px, transparent 1.6px),
    radial-gradient(circle at 87.8% 9.1%, rgba(255,247,238,0.74) 0.8px, transparent 1.6px),
    radial-gradient(circle at 79.7% 58.4%, rgba(255,247,238,0.41) 1px, transparent 1.8px),
    radial-gradient(circle at 64.8% 68.5%, rgba(255,247,238,0.58) 1px, transparent 1.8px),
    radial-gradient(circle at 58.0% 19.0%, rgba(255,247,238,0.42) 1px, transparent 1.8px),
    radial-gradient(circle at 6.4% 80.4%, rgba(255,247,238,0.44) 1px, transparent 1.8px),
    radial-gradient(circle at 10.7% 32.2%, rgba(255,247,238,0.76) 1.3px, transparent 2.1px),
    radial-gradient(circle at 46.5% 66.0%, rgba(255,247,238,0.46) 1.3px, transparent 2.1px),
    radial-gradient(circle at 17.8% 90.8%, rgba(255,247,238,0.83) 0.8px, transparent 1.6px),
    radial-gradient(circle at 59.2% 14.7%, rgba(255,247,238,0.75) 1px, transparent 1.8px),
    radial-gradient(circle at 77.1% 42.7%, rgba(255,247,238,0.63) 1px, transparent 1.8px),
    radial-gradient(circle at 57.5% 75.1%, rgba(255,247,238,0.37) 1.3px, transparent 2.1px),
    radial-gradient(circle at 14.4% 3.6%, rgba(255,247,238,0.84) 1px, transparent 1.8px),
    radial-gradient(circle at 18.9% 80.8%, rgba(255,247,238,0.45) 0.8px, transparent 1.6px),
    radial-gradient(circle at 44.8% 29.5%, rgba(255,247,238,0.56) 0.8px, transparent 1.6px),
    radial-gradient(circle at 2.8% 11.9%, rgba(255,247,238,0.35) 0.8px, transparent 1.6px),
    radial-gradient(circle at 11.0% 15.9%, rgba(255,247,238,0.36) 0.8px, transparent 1.6px),
    radial-gradient(circle at 63.2% 45.4%, rgba(255,247,238,0.65) 0.6px, transparent 1.4px),
    radial-gradient(circle at 82.5% 25.5%, rgba(255,247,238,0.77) 1px, transparent 1.8px),
    radial-gradient(circle at 83.5% 43.3%, rgba(255,247,238,0.7) 1px, transparent 1.8px);
    -webkit-mask-image: linear-gradient(#000 40%, transparent); mask-image: linear-gradient(#000 40%, transparent); }
  .logo { margin: 0; font: italic 900 clamp(56px, 14vw, 128px)/.9 "Futura", "Avenir Next", "Helvetica Neue", sans-serif; letter-spacing: -.02em;
    background: linear-gradient(180deg, #fff 0%, #fff 42%, #ffd2f0 48%, #ff7ad0 60%, #ffd23f 100%); -webkit-background-clip: text; background-clip: text;
    color: transparent; filter: drop-shadow(0 3px 0 #3a0a5e) drop-shadow(0 0 22px rgba(255,63,164,.55)); }
  /* The stripes run exactly as wide as the tagline under them. */
  .lockup { display: inline-block; max-width: 34em; }
  .stripes { width: 100%; height: 18px; margin: 18px 0 0;
    background: linear-gradient(#ff3b30 0 20%, transparent 20% 25%, #ff9500 25% 45%, transparent 45% 50%, #ffd60a 50% 70%, transparent 70% 75%, #33e1ff 75% 95%, transparent 95%); }
  .tagline { margin: 18px auto 0; max-width: 34em; font-size: clamp(18px, 2.6vw, 22px); font-weight: 600; color: var(--ink); }

  .hero { display: grid; grid-template-columns: minmax(0, 1.1fr) minmax(0, 1fr); gap: 40px; align-items: center; padding: 36px 0 24px; }
  .hero img { width: 100%; height: auto; filter: drop-shadow(0 24px 40px rgba(20,5,46,.55)); }
  .pitch p { margin: 0 0 14px; color: var(--ink); }
  .buttons { display: flex; flex-wrap: wrap; gap: 12px; margin: 22px 0 8px; }
  .btn { display: inline-flex; align-items: center; gap: 8px; padding: 13px 22px; border-radius: 999px; font-weight: 800; text-decoration: none;
    letter-spacing: .02em; transition: transform .12s; }
  .btn:hover { transform: translateY(-2px); }
  .btn.main { background: var(--sun); color: #2c0a5e; box-shadow: 0 6px 0 #b36b00, 0 10px 24px rgba(20,5,46,.4); }
  .btn.alt { background: rgba(20,5,46,.45); border: 2px solid rgba(255,247,238,.6); }
  .small { font-size: 14px; color: var(--dim); }

  section.wrap { padding: 72px 16px; }
  h2 { margin: 0 0 18px; font: italic 900 clamp(28px, 4.6vw, 40px)/1.05 "Futura", "Avenir Next", sans-serif; text-transform: uppercase; letter-spacing: .01em;
    text-shadow: 0 3px 0 rgba(58,10,94,.8); }
  .features { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 16px; }
  .card { padding: 18px 18px 16px; border-radius: 16px; background: rgba(20,5,46,.5); border: 1px solid rgba(255,247,238,.18); }
  .card h3 { margin: 0 0 6px; font: 800 17px/1.25 "Avenir Next", -apple-system, sans-serif; color: var(--sun); }
  .card p { margin: 0; font-size: 15.5px; color: var(--ink); }

  .tapes { display: grid; grid-template-columns: 1fr 1fr; gap: 24px; align-items: center; }
  .tapes img { width: 100%; height: auto; filter: drop-shadow(0 16px 28px rgba(20,5,46,.5)); }
  .tapes img:nth-child(1) { transform: rotate(-3deg); }
  .tapes img:nth-child(2) { transform: rotate(2.5deg); }

  .free img { width: 100%; height: auto; margin: 8px 0 24px; filter: drop-shadow(0 16px 28px rgba(20,5,46,.5)); }
  .free p { margin: 0; max-width: 40em; }
  .free h2.addons { margin-top: 72px; }
  .free > p { margin-bottom: 24px; }
  .free .buttons { margin: 24px 0 72px; }
  .free .buttons:last-child { margin-bottom: 0; }
  .story { max-width: 44em; }
  .donate { margin-top: 72px; text-align: center; }
  .donate p { margin-bottom: 0; }
  .donate .buttons { justify-content: center; margin: 24px 0 0; }
  .donate .btn { background: #b8323a; border: 2px solid rgba(255,247,238,.45); color: #fff7ee; box-shadow: 0 6px 0 #7e1d24, 0 10px 24px rgba(20,5,46,.3); }
  .story p { margin: 0 0 24px; color: #2c0a5e; font-weight: 500; line-height: 1.6; }
  .claim { font: italic 900 clamp(22px, 3.4vw, 30px)/1.2 "Futura", "Avenir Next", sans-serif; color: #2c0a5e; margin-top: 48px; }
  footer { padding: 36px 0 48px; text-align: center; color: #2c0a5e; font-weight: 600; font-size: 14px; }
  footer a { color: #2c0a5e; }

  @media (max-width: 760px) {
    header.wrap { padding-top: 64px; }
    .hero { grid-template-columns: 1fr; gap: 20px; padding-top: 24px; }
    .features { grid-template-columns: 1fr; }
    .tapes { grid-template-columns: 1fr; }
  }
</style>
</head>
<body>
<div id="unwrap"><p id="msg">Unwrapping your mixtape …</p><div id="bar"><i></i></div></div>

<div id="home">
  <header class="wrap">
    <h1 class="logo">MIXTAPE</h1>
    <div class="lockup">
      <div class="stripes" aria-hidden="true"></div>
      <p class="tagline">The perfect simulation of an audio cassette for your Mac – just like in 1986.</p>
    </div>
  </header>

  <div class="wrap hero">
    <img src="site/hero.png" alt="A yellow cassette labelled 90’s Indie Rock, with the tape deck and VU meters below it" width="760" height="713">
    <div class="pitch">
      <p>A cassette on your Mac desktop. Tape whatever your Mac is playing – a song on Spotify, a clip on YouTube, an Instagram reel (if you REALLY have to) – or your own voice introducing the next song.</p>
      <p>Flip it over, punch the title onto label tape, and send it to a friend. They don’t even need the app: one tap on the link and the tape plays – on a phone it fills the whole screen.</p>
      <div class="buttons">
        <a class="btn main" href="https://aeiou11235.itch.io/mixtape-app">⬇ Download for Mac – free</a>
        <a class="btn alt" href="https://github.com/aeiou11235/mixtape/releases/latest">GitHub</a>
      </div>
      <p class="small">macOS 14.4 or later · Apple silicon &amp; Intel · pay what you want</p>
    </div>
  </div>

  <section class="wrap">
    <h2>What it does</h2>
    <div class="features">
      <div class="card"><h3>Records what your Mac plays</h3><p>Spotify, YouTube, anything – or the microphone. Real time only: you hit PAUSE at just the right moment, and the pause key squeaks.</p></div>
      <div class="card"><h3>Like real tape</h3><p>Recording overwrites what was there. C46, C60 or C90, side A and side B. Break out the tab and REC won’t go down.</p></div>
      <div class="card"><h3>Label tape</h3><p>Punch titles onto embossed plastic strips – 16 colours, as many as you like, anywhere on the cassette. No delete key: go back and press over it.</p></div>
      <div class="card"><h3>Send it as a link</h3><p>One tap and it plays, on any phone or computer. Encrypted on your Mac – the key travels only in the link, so the server can’t read it.</p></div>
      <div class="card"><h3>Tape sound</h3><p>Hiss, wow &amp; flutter, tape tone, winding noise, key clunks – each with its own slider. VU meters and a REC LEVEL fader that saturates like tape.</p></div>
      <div class="card"><h3>Cassette designs</h3><p>Ferro, Chrome, Metal and Clear, worn like real ones – and <a href="#designs">three colourful packs</a>: Neon, Jelly and Vintage.</p></div>
    </div>
  </section>

  <section class="wrap tapes" aria-label="Some tapes">
    <img src="site/japanoise.png" alt="A worn clear cassette labelled Japanoise" width="560" height="367" loading="lazy">
    <img src="site/darkwave.png" alt="A black cassette with label strips: Dark Wave, Goth, The Cure" width="560" height="368" loading="lazy">
  </section>

  <section class="wrap free" id="designs">
    <h2>Cassette designs</h2>
    <p>Mixtape comes with four cassettes – Ferro, Chrome, Metal and Clear – well used, scratched and stained, every one its own way.</p>
    <img src="site/base-designs.png" alt="The four cassettes Mixtape comes with: Ferro, Chrome, Metal and Clear" width="1200" height="196" loading="lazy">
    <h2 class="addons">Add-ons</h2>
    <p>Want colour? Three packs of three, <b>3 USD each</b> on itch.io. Buy one, double-click the file, and the cassettes appear under <b>New Cassette</b> – as C46, C60 or C90.</p>
    <a href="https://aeiou11235.itch.io/mixtape-neon-pack"><img src="site/pack-neon.png" alt="Neon Pack: Pink Neon, Yellow Rainbow, Blue Memphis" width="1200" height="376" loading="lazy"></a>
    <p><b>Neon Pack</b> – Pink Neon, Yellow Rainbow and Blue Memphis.</p>
    <div class="buttons"><a class="btn main" href="https://aeiou11235.itch.io/mixtape-neon-pack">Neon Pack – 3 USD</a></div>
    <a href="https://aeiou11235.itch.io/mixtape-jelly-pack"><img src="site/pack-jelly.png" alt="Jelly Pack: Mint, Orange and Grape Jelly" width="1200" height="375" loading="lazy"></a>
    <p><b>Jelly Pack</b> – see-through Mint, Orange and the new Grape Jelly.</p>
    <div class="buttons"><a class="btn main" href="https://aeiou11235.itch.io/mixtape-jelly-pack">Jelly Pack – 3 USD</a></div>
    <a href="https://aeiou11235.itch.io/mixtape-vintage-pack"><img src="site/pack-vintage.png" alt="Vintage Pack: Clear, Beige and Black" width="1200" height="375" loading="lazy"></a>
    <p><b>Vintage Pack</b> – Clear, Beige and Black with red stripes, like from the supermarket in 1986.</p>
    <div class="buttons"><a class="btn main" href="https://aeiou11235.itch.io/mixtape-vintage-pack">Vintage Pack – 3 USD</a></div>
  </section>

  <section class="wrap story">
    <h2>The story behind it</h2>
    <p>I’m old enough to have done this for real. In 1986, where I grew up – in the south of Germany near the Czech border – our local record store only had country music. Swapping tapes with friends was the only way to hear anything new. We put real effort into every mixtape, because we made them for each other. A good tape was a sign of friendship.</p>
    <p>Tapes stayed with me. In Berlin in the 90s, cassettes were still the medium of the underground, passed from hand to hand. That’s the feeling Mixtape brings back – into the digital age. You’re not recording for yourself. You’re recording for your friends.</p>
    <p class="claim">Make the perfect mixtape. Share it with friends.</p>
    <div class="donate">
      <p>Mixtape itself stays free. If you like it, a small donation keeps it going.</p>
      <div class="buttons"><a class="btn alt" href="https://aeiou11235.itch.io/mixtape-app/purchase">♥ Donate on itch.io</a></div>
    </div>
  </section>

  <footer class="wrap">
    Made by AEIOU · <a href="https://aeiou11235.itch.io/mixtape-app">itch.io</a> · <a href="https://github.com/aeiou11235/mixtape">GitHub</a>
  </footer>
</div>

<script>
// A shared tape: …/#<tape>.<key>. The part after # never leaves this browser: the tape is fetched
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
// Reads the tape in pieces so the bar can show how much has arrived.
async function download(res, bar) {
  const total = +res.headers.get('Content-Length') || 0;
  if (!total || !res.body) bar.classList.add('unknown');
  if (!res.body) return new Uint8Array(await res.arrayBuffer());
  const reader = res.body.getReader(), parts = [];
  let got = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    parts.push(value);
    got += value.length;
    if (total) bar.firstChild.style.width = Math.min(100, got / total * 100) + '%';
  }
  const box = new Uint8Array(got);
  let at = 0;
  for (const p of parts) { box.set(p, at); at += p.length; }
  return box;
}
(async () => {
  // Without a tape after the #, this is just the home page – also for #designs and other sections.
  if (location.hash.length < 2 || document.getElementById(decodeURIComponent(location.hash.slice(1)))) return;
  document.body.classList.add('tape');
  const bar = document.getElementById('bar');
  const say = t => { document.getElementById('msg').textContent = t; bar.classList.add('gone'); };
  const [id, k] = location.hash.slice(1).split('.');
  if (!/^[A-Za-z0-9]{10}$/.test(id || '') || !k) return say('This link is incomplete – ask for it again.');
  try {
    const res = await fetch(`t/${id}.bin`, { cache: 'no-store' });
    if (!res.ok) return say('This tape has run out – ask for a new link.');
    const box = await download(res, bar);
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
