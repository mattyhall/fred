* in-editor recording to be used in tests
  * would open a test file
  * you'd then do a series of commands
  * it'd record the output of each draw
  * this would be saved somewhere
  * tests could read the file and test against it
  * concerns
    * output files would get massive?
      * should have fairly low entropy so compression will help
    * would need the same size terminal every time?
      * could scale down current one
* tree sitter for syntax highlighting
* embed lua for configuration/scripting/plugins
  * could use some other language...? js with duktape?
  * maybe write my own?
* server/client architecture
  * this is what kak does
* fuzzy finding with fzf
  * just use tmux as the window?
  * how does it work searching files
* lsp mode
* git gutter
* plugins
  * org-mode
  * magit
