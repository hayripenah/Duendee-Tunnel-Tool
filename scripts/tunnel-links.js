export function sameUrl(a, b) {
  const norm = (value) => String(value || '').trim().replace(/\/+$/, '').toLowerCase();
  return norm(a) !== '' && norm(a) === norm(b);
}

export function trycloudflareUrls(text) {
  const found = String(text || '').match(/https:\/\/[a-zA-Z0-9-]+\.trycloudflare\.com/gi) || [];
  return [...new Set(found.map((item) => item.replace(/\/+$/, '')))];
}

export function tunnelLinksToDrop(urls, keepUrl) {
  return trycloudflareUrls(urls.join('\n')).filter((item) => !sameUrl(item, keepUrl));
}
