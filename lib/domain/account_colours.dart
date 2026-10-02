/// The colours an account can have, and what became of the ones it could
/// have before.
///
/// Every colour here is one Android draws as it is. A mail notification
/// shows the account's colour on the small icon, and Android first darkens
/// that colour until it stands out 4.5 to 1 against the light shade (and
/// lightens it against the dark one). Mint, chosen for Gmail on Ron's phone,
/// came out a dark green (`#00B294` in the app, `#00775D` in the shade,
/// measured on 2026-10-01), so the app and the notification no longer
/// agreed. These are all dark enough to pass by day, so what the app shows
/// is what the shade shows from 06:00 to 22:00. At night, against the dark
/// shade, Android lightens them; no colour passes both ways.
library;

/// Every colour an account can have, by shade: blues, teals, greens,
/// yellows, oranges, browns, reds, pinks, purples, greys.
///
/// Each is at most 0.128 in relative luminance, which keeps 4.5 to 1
/// against a light surface of tone 90 with room to spare (the phone's shade
/// measured about tone 93). Blue, indigo and green sit a hair above that
/// and are kept as they were: Android moves them by less than can be seen.
/// No two are closer than 9.4 in CIEDE2000.
const accountPalette = [
  0xFF003966, // navy
  0xFF0F6CBD, // blue
  0xFF28597D, // steel
  0xFF5B5FC7, // indigo
  0xFF0A6576, // teal
  0xFF007258, // mint
  0xFF107C41, // green
  0xFF236123, // forest
  0xFF4D6E06, // olive
  0xFF766305, // khaki
  0xFF8A5A05, // ochre
  0xFFB23C00, // orange
  0xFF843514, // rust
  0xFF8E562E, // brown
  0xFF8F383E, // rosewood
  0xFFB3261E, // red
  0xFFC50F4A, // raspberry
  0xFFC00F70, // pink
  0xFFB4009E, // magenta
  0xFF661B4A, // plum
  0xFF7553A6, // lavender
  0xFF5C2E91, // purple
  0xFF55676E, // slate
  0xFF393939, // charcoal
];

/// What new accounts are given, in turn: eight from [accountPalette] far
/// apart (15 or more in CIEDE2000), so a fifth account no longer came out
/// the first one's blue. Any colour on the account's own screen can
/// replace it.
const newAccountColours = [
  0xFF0F6CBD, // blue
  0xFF107C41, // green
  0xFFB4009E, // magenta
  0xFFB23C00, // orange
  0xFF0A6576, // teal
  0xFF7553A6, // lavender
  0xFFC50F4A, // raspberry
  0xFF766305, // khaki
];

/// The colour an account stored as [value] has now.
///
/// A colour from the palette before 2.75.1 that Android redrew becomes the
/// one closest to how Android drew it, so the shade looks as it did and the
/// app now agrees with it. Two may land on one: cyan and teal were already
/// the same colour in the shade, as were orange and burnt orange. Anything
/// else, a palette colour or one from outside it, is left as it is.
int currentAccountColour(int value) => _retired[value] ?? value;

const _retired = {
  0xFF4F9FE0: 0xFF0F6CBD, // sky -> blue
  0xFF00B7C3: 0xFF0A6576, // cyan -> teal
  0xFF00838F: 0xFF0A6576, // teal
  0xFF00B294: 0xFF007258, // mint
  0xFF13A10E: 0xFF236123, // bright green -> forest
  0xFF498205: 0xFF4D6E06, // olive
  0xFFC19C00: 0xFF766305, // gold -> khaki
  0xFFFFB900: 0xFF8A5A05, // amber -> ochre
  0xFFF7630C: 0xFFB23C00, // orange
  0xFFCA5010: 0xFFB23C00, // burnt orange -> orange
  0xFFE81123: 0xFFB3261E, // red (the old dark red)
  0xFFEA005E: 0xFFC50F4A, // raspberry
  0xFFE3008C: 0xFFC00F70, // pink
  0xFF8764B8: 0xFF7553A6, // lavender
  0xFF69797E: 0xFF55676E, // slate
};
