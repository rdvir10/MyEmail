/// Which part of a message a search looks in.
///
/// [all] is what a search box does unasked: subject, sender and body
/// together. The others narrow it to one, for the search that knows what it
/// is after: everything from a person, or a word that is in the subject and
/// nowhere else. Ron asked for the three.
enum SearchField {
  all('All'),
  from('From'),
  subject('Subject'),
  body('Body');

  const SearchField(this.label);

  /// The chooser's label.
  final String label;
}
