// Vercel serverless function. The Timely web build (running in a browser)
// can't call *.webuntis.com directly - WebUntis doesn't send the
// Access-Control-Allow-Origin header a browser requires, so the request
// gets blocked by CORS before it even leaves the browser. This function
// runs server-side (no browser, no CORS) and simply forwards the request
// on Timely's behalf, then hands the response back to the browser from
// Timely's own domain - which the browser is always allowed to read.
//
// Only ever used by the web build; the Android/iOS app calls WebUntis
// directly since native apps aren't subject to browser CORS at all.

module.exports = async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'Method not allowed' });
    return;
  }

  const target = req.query.url;
  if (!target) {
    res.status(400).json({ error: 'Missing url parameter' });
    return;
  }

  let parsed;
  try {
    parsed = new URL(target);
  } catch (e) {
    res.status(400).json({ error: 'Invalid url parameter' });
    return;
  }

  // This must never become a general-purpose open proxy: only ever
  // forward to a genuine WebUntis host over https.
  if (parsed.protocol !== 'https:' || !parsed.hostname.endsWith('.webuntis.com')) {
    res.status(400).json({ error: 'Only https://*.webuntis.com URLs are allowed' });
    return;
  }

  // Vercel parses a JSON request body into req.body automatically; put it
  // back into a plain string to forward it on unchanged.
  const bodyText = typeof req.body === 'string' ? req.body : JSON.stringify(req.body);

  try {
    const upstream = await fetch(parsed.toString(), {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      body: bodyText,
    });

    const text = await upstream.text();
    res.status(upstream.status);
    res.setHeader('Content-Type', 'application/json');
    res.send(text);
  } catch (err) {
    res.status(502).json({ error: 'Upstream request failed: ' + String(err) });
  }
};
