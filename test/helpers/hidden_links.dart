/// Messages that hold no `<link>` tag as a browser reads them, but would
/// hold one if something taken out on the way to the page let the text
/// around it join: a tag taken out for a space right after a `<link`
/// (another link, a `<meta>`, a `<base>`), or a stray `<html>` or `<head>`
/// taken out for nothing right after a `<`. Each href is written so no
/// pattern sees its host. For what the message view and the printer are
/// given with pictures blocked (November review #126).
const hiddenLinks = [
  '<link<link >rel=preconnect href="&#104;ttps://u1.t.example">',
  '<link<meta >rel=preconnect href="&#104;ttps://u1.t.example">',
  '<link<base x>rel=dns-prefetch href="&#104;ttps://u1.t.example">',
  '<LINK< META>rel=preconnect href="&#104;ttps://u1.t.example">',
  '<html><<html>link rel=preconnect href="&#104;ttps://u1.t.example"></html>',
  '<html><<head></head>link rel=preconnect '
      'href="&#104;ttps://u1.t.example"></html>',
];
