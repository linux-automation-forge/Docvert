One bash script: image converter, document converter, and a smallPDF toolbox — merge, split, and remove pages. A safe, consistent CLIover ImageMagick, Ghostscript, pdftk and libreoffice.

commands
images — batch convert with savings report
./docvert.sh image *.png --to webp -q 80./docvert.sh image photo.jpg --to png --resize 50%
Every file shows before → after sizes with % saved, plus totals.

PDF toolbox
./docvert.sh pdf-merge combined.pdf part1.pdf part2.pdf./docvert.sh pdf-split book.pdf 1-5 summary.pdf        # keep pages 1-5./docvert.sh pdf-rm scan.pdf 2,4 clean.pdf             # delete pages 2 & 4./docvert.sh from-pdf document.pdf                     # → page-N.png each
Page specs are strict: 3 or 1-5,8,10-12. Bad specs get rejected withexamples. Fake PDFs (wrong header) get rejected before any tool chokes.

anything → PDF
./docvert.sh to-pdf screenshot.png     # images./docvert.sh to-pdf notes.md           # text./docvert.sh to-pdf page.html          # html (needs wkhtmltopdf)./docvert.sh to-pdf report.docx        # office (needs libreoffice)
safety design
never overwrites: existing outputs get -1, -2 suffixes (-f to force)
keeps originals always — conversions create new files
PDF header check before merging/splitting
strict page-range parsing with human error messages
install engines (only what you need)
sudo apt install -y imagemagick                     # images + to/from-pdfsudo apt install -y ghostscript poppler-utils pdftk # pdf merge/split/rmsudo apt install -y wkhtmltopdf                     # html → pdfsudo apt install -y libreoffice                     # docx/odt → pdf (big)
self-test (offline, temp folder)
./docvert.sh --selftest
Runs page-parser edge cases, collision-suffix checks, and a real png→jpground-trip. Want: pass=9 fail=0.

bash 4+, coreutils. Engines optional per feature. MIT licensed.
