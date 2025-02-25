# xchange
xchange is a general purpose text preprocessor with explicit macro calls

It was created to be a separate entity for use in any sort of document to allow quickly handling repetative tasks

## Q&A
- Why make a macro system when others exist?
  - xchange was made to be simple to use while giving enough functionality in ways that other macro systems do not, specifically in duplication using @each and @repeat macros
- Why have explicit macro calls instead of implicit like the C preprocessor?
  - Implicit macro calls can lead to what you've typed not being exactly what you expect to have happen. By making it explicit, you know exactly when a macro is coming into play. It also allows processing to be easier as xchange can always know when it needs to do something