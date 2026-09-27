/// Which part of a message a search looks in.
///
/// [all] is what a search box does unasked: subject, sender and body
/// together. The others narrow it to one, for the search that knows what it
/// is after: everything from a person, a word that is in the subject and
/// nowhere else, or a file by its name. Ron asked for the three, then the
/// attachments.
enum SearchField {
  all('All'),
  from('From'),
  subject('Subject'),
  body('Body'),

  /// The names of the files on a message, not what is in them.
  attachment('Attachment');

  const SearchField(this.label);

  /// The chooser's label.
  final String label;
}
