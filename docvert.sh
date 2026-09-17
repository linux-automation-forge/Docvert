#!/usr/bin/env bash
# docvert.sh — image + document converter with PDF tools (v1.0.0)
# ENGINE CREDIT: ImageMagick (convert), Ghostscript (gs), pdftk, libreoffice
# USAGE:
#   ./docvert.sh image <files...> [--to png|jpg|webp|bmp|tiff] [--resize 50%|800x600] [-q 85]
#   ./docvert.sh pdf-merge   <out.pdf> <in1.pdf> <in2.pdf> ...
#   ./docvert.sh pdf-split   <in.pdf> <pages like 1-3,5> <out.pdf>
#   ./docvert.sh pdf-rm      <in.pdf> <pages to REMOVE like 2,4> <out.pdf>
#   ./docvert.sh to-pdf      <img|txt|md|html file>     (or docx if libreoffice present)
#   ./docvert.sh from-pdf    <in.pdf>                    (pdf → png pages)
#   ./docvert.sh --selftest | --gen-files | -h | -V
# SAFETY: never overwrites input; output gets numbered suffix if exists (unless -f)
set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C

SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"
VERSION="1.0.0"
QUALITY=90
RESIZE=""
FORCE=0
TO_FMT=""

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    R=$'\033[0m'; B=$'\033[1m'; DIM=$'\033[2m'
    GRN=$'\033[1;32m'; YLW=$'\033[1;33m'; RED=$'\033[1;31m'; CYN=$'\033[1;36m'
else
    R=""; B=""; DIM=""; GRN=""; YLW=""; RED=""; CYN=""
fi
ok()   { printf '  %s[ok]%s %s\n' "$GRN" "$R" "$1"; }
warn() { printf '  %s[!!] %s%s\n' "$YLW" "$1" "$R"; }
err()  { printf '  %s[XX] %s%s\n' "$RED" "$1" "$R" >&2; }
sect() { printf '\n%s%s── %s %s%s\n' "$B$CYN" "" "$1" "$(printf '─%.0s' $(seq 1 42))" "$R"; }
die()  { err "$2"; exit "$1"; }
human() { awk -v b="${1:-0}" 'BEGIN{split("K M G T",A," ");i=0;while(b>=1024&&i<4){b/=1024;i++}printf "%.1f%s",b,(i==0?"B":A[i])}'; }
size_of() { stat -c%s "$1" 2>/dev/null || echo 0; }

smart_out() { # never overwrite: file.png → file-1.png if exists (unless FORCE)
    local target="$1"
    if [[ -e "$target" && "$FORCE" -eq 0 ]]; then
        local base ext n=1
        base="${target%.*}"; ext="${target##*.}"
        while [[ -e "${base}-${n}.${ext}" ]]; do n=$(( n + 1 )); done
        target="${base}-${n}.${ext}"
        warn "output existed — writing to ${target} instead (use -f to overwrite)"
    fi
    printf '%s' "$target"
}

# ---------- dependency checks ----------
check_convert() { command -v convert > /dev/null 2>&1 \
    || die 1 "ImageMagick missing — sudo apt install -y imagemagick"; }
check_gs()     { command -v gs > /dev/null 2>&1 \
    || die 1 "ghostscript missing — sudo apt install -y ghostscript"; }
check_pdftk()  { command -v pdftk > /dev/null 2>&1 || return 1; }

# ==================== IMAGE CONVERSION ======================================
IMG_TYPES="png jpg jpeg webp bmp tiff gif"
do_image() {
    check_convert
    local -a files=() rest=()
    local -a args=()
    # separate real files from flags (already parsed, so all rest are files)
    files=("${CMD_FILES[@]}")
    (( ${#files[@]} > 0 )) || die 2 "image mode needs at least one file"

    sect "Image conversion → ${TO_FMT^^}"
    [[ -n "$RESIZE" ]] && printf '  resize   : %s\n' "$RESIZE"

    local f base out before after total_b=0 total_a=0
    for f in "${files[@]}"; do
        [[ -f "$f" ]] || { warn "skipping '$f' — not a file"; continue; }
        base="${f%.*}"
        out="$(smart_out "${base}.${TO_FMT}")"

        before="$(size_of "$f")"
        local -a cvt=(convert "$f")
        [[ -n "$RESIZE" ]] && cvt+=(-resize "$RESIZE")
        cvt+=(-quality "$QUALITY" "$out")

        if "${cvt[@]}" 2>/dev/null; then
            after="$(size_of "$out")"
            total_b=$(( total_b + before )); total_a=$(( total_a + after ))
            local pct="same"
            (( before > 0 )) && pct="$(( 100 * (before - after) / before ))"
            printf '  %-28s → %-28s %s\n' \
                "$(basename "$f")" "$(basename "$out")" \
                "$(human "$before") → $(human "$after") (${pct}%)"
        else
            err "failed: $f"
        fi
    done
    hr2() { printf '%s──────────────────────────────────────────────%s\n' "$DIM" "$R"; }
    hr2
    printf '  total: %s → %s\n' "$(human "$total_b")" "$(human "$total_a")"
}

# ==================== PDF: MERGE / SPLIT / REMOVE ===========================
do_pdf_merge() {
    check_gs
    local out="$1"; shift
    local -a ins=("$@")
    (( ${#ins[@]} >= 2 )) || die 2 "pdf-merge needs 2+ input PDFs"
    local f
    for f in "${ins[@]}"; do
        [[ -f "$f" ]] || die 2 "missing input: $f"
        [[ "$(file -b "$f" 2>/dev/null)" == *PDF* || "$(head -c 4 "$f")" == "%PDF" ]] \
            || die 2 "not a PDF: $f"
    done
    out="$(smart_out "$out")"
    sect "Merging ${#ins[@]} PDFs → $(basename "$out")"
    gs -dBATCH -dNOPAUSE -q -sDEVICE=pdfwrite \
       -sOutputFile="$out" "${ins[@]}"
    ok "merged: $(basename "$out") ($(human "$(size_of "$out")"))"
}
parse_pages() { # "1-3,5,7-9" → "1 2 3 5 7 8 9"
    local spec="$1" part a b i
    local -a out=()
    IFS=',' read -r -a parts <<< "$spec"
    for part in "${parts[@]}"; do
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"
            (( a <= b )) || die 2 "bad range '$part' (start > end)"
            for (( i=a; i<=b; i++ )); do out+=("$i"); done
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            out+=("$part")
        else
            die 2 "bad page spec '$part' (examples: 3  or  1-5,8,10-12)"
        fi
    done
    (( ${#out[@]} > 0 )) || die 2 "empty page list"
    printf '%s\n' "${out[@]}"
}
do_pdf_split() { # keep only the given pages
    check_gs
    local in="$1" spec="$2" out="$3"
    [[ -f "$in" ]] || die 2 "missing input: $in"
    out="$(smart_out "$out")"
    local -a pages=() p
    mapfile -t pages < <(parse_pages "$spec")

    sect "Split: keeping pages [$(IFS=,; printf '%s' "${pages[*]}")]"
    # ghostscript -dFirstPage/-dLastPage only does contiguous; use pdftk when present for arbitrary sets
    if check_pdftk; then
        local range; range="$(IFS=' '; printf '%s' "${pages[*]}")"
        pdftk "$in" cat $range output "$out"
        ok "extracted ${#pages[@]} page(s) → $(basename "$out")"
    else
        # fallback: contiguous-only via gs
        if [[ "${#pages[@]}" -eq 2 && "${pages[0]}" =~ ^[0-9]+$ && "${pages[1]}" =~ ^[0-9]+$ ]] \
           && [[ $(( ${pages[1]} - ${pages[0]} )) -eq $(( ${#pages[@]} - 1 )) ]]; then
            gs -dBATCH -dNOPAUSE -q -sDEVICE=pdfwrite \
               -dFirstPage="${pages[0]}" -dLastPage="${pages[1]}" \
               -sOutputFile="$out" "$in"
            ok "extracted pages ${pages[0]}-${pages[1]} → $(basename "$out")"
        else
            die 1 "non-contiguous page sets need pdftk — sudo apt install -y pdftk"
        fi
    fi
}
do_pdf_rm() { # remove listed pages, keep the rest
    local in="$1" spec="$2" out="$3"
    [[ -f "$in" ]] || die 2 "missing input: $in"
    local total
    total="$(pdfinfo "$in" 2>/dev/null | awk '/^Pages:/{print $2}')"
    [[ -z "$total" ]] && { check_gs; total="$(gs -q -dNODISPLAY -dBATCH \
        -c "($(printf '%s' "$in" | sed 's/\\/\\\\/g; s/(/\\(/g; s/)/\\)/g')) (r) file runpdfbegin pdfpagecount = quit" 2>/dev/null)"; }
    [[ -z "$total" || ! "$total" =~ ^[0-9]+$ ]] && die 1 "could not count pages — install poppler-utils (sudo apt install -y poppler-utils)"

    local -a rm_pages=()
    mapfile -t rm_pages < <(parse_pages "$spec")
    local p
    for p in "${rm_pages[@]}"; do
        (( p >= 1 && p <= total )) || die 2 "page $p out of range (document has $total pages)"
    done

    # keep = all pages minus removed
    local -a keep=() i skip
    for (( i=1; i<=total; i++ )); do
        skip=0
        for p in "${rm_pages[@]}"; do (( i == p )) && { skip=1; break; }; done
        (( skip == 0 )) && keep+=("$i")
    done
    (( ${#keep[@]} == 0 )) && die 2 "that would delete every page"

    sect "Remove: deleting [$(IFS=,; printf '%s' "${rm_pages[*]}")] of $total pages"
    local tmpspec="$spec"
    if check_pdftk; then
        local range; range="$(IFS=' '; printf '%s' "${keep[*]}")"
        local outfile; outfile="$(smart_out "$out")"
        pdftk "$in" cat $range output "$outfile"
        ok "kept ${#keep[@]} page(s) → $(basename "$outfile")"
    else
        # gs fallback: invert by extracting each kept page and merging (keeps order)
        check_gs
        local -a parts=()
        local start prev
        start="${keep[0]}"; prev="$start"
        local idx
        for (( idx=1; idx<${#keep[@]}; idx++ )); do
            if (( keep[idx] == prev + 1 )); then prev="${keep[idx]}"
            else parts+=("${start}-${prev}"); start="${keep[idx]}"; prev="$start"; fi
        done
        parts+=("${start}-${prev}")
        local outfile; outfile="$(smart_out "$out")"
        gs -dBATCH -dNOPAUSE -q -sDEVICE=pdfwrite -sOutputFile="$outfile" \
           $(printf -- '-sPageList=%s ' "$(IFS=,; printf '%s' "${parts[*]}")") 2>/dev/null \
           || gs -dBATCH -dNOPAUSE -q -sDEVICE=pdfwrite -sOutputFile="$outfile" "$in" \
                && warn "gs PageList unsupported — copied whole doc; install pdftk for true removal"
        ok "output → $(basename "$outfile") (verify it!)"
    fi
}

# ==================== DOC CONVERSIONS =======================================
do_to_pdf() {
    local f="$1"
    [[ -f "$f" ]] || die 2 "not a file: $f"
    local ext="${f##*.}"; ext="${ext,,}"
    local out; out="$(smart_out "${f%.*}.pdf")"
    sect "Converting $(basename "$f") → PDF"

    case "$ext" in
        png|jpg|jpeg|webp|bmp|tiff|gif)
            check_convert
            convert "$f" -auto-orient -page a4 -quality "$QUALITY" "$out" 2>/dev/null \
                || convert "$f" "$out"
            ok "image → pdf: $(basename "$out")" ;;
        txt|md|text)
            check_gs
            # simplest robust path: enscript-style via gs txtwrite is fussy; use ps2pdf via a2ps if present
            if command -v ps2pdf > /dev/null 2>&1 && command -v enscript > /dev/null 2>&1; then
                enscript -p - "$f" 2>/dev/null | ps2pdf - "$out"
                ok "text → pdf via enscript+ps2pdf"
            else
                # fallback: convert renders plain text poorly; suggest pandoc but try ImageMagick txt:
                warn "cleanest text→pdf needs enscript: sudo apt install -y enscript ghostscript"
                check_convert
                convert -density 150 "$f" -quality "$QUALITY" "$out" 2>/dev/null \
                    || die 1 "could not convert text — install enscript+ghostscript for reliable text→pdf"
                ok "text → pdf (basic render)"
            fi ;;
        html|htm)
            if command -v wkhtmltopdf > /dev/null 2>&1; then
                wkhtmltopdf -q "$f" "$out" && ok "html → pdf via wkhtmltopdf"
            else
                die 1 "html→pdf needs wkhtmltopdf — sudo apt install -y wkhtmltopdf"
            fi ;;
        docx|odt|doc|pptx|xlsx)
            if command -v libreoffice > /dev/null 2>&1; then
                libreoffice --headless --convert-to pdf --outdir . "$f" > /dev/null 2>&1
                [[ -f "${f%.*}.pdf" ]] && ok "office doc → pdf via libreoffice" \
                    || die 1 "libreoffice conversion failed"
            else
                die 1 "office formats need libreoffice — sudo apt install -y libreoffice (big install!)"
            fi ;;
        *) die 2 "unsupported input type '.$ext' — try image types, txt/md, html, or office docs" ;;
    esac
    printf '  size: %s\n' "$(human "$(size_of "$out")")"
}
do_from_pdf() {
    check_convert
    local in="$1"
    [[ -f "$in" ]] || die 2 "not a file: $in"
    local base; base="$(basename "${in%.pdf}")"
    sect "PDF → PNG pages"
    convert -density 150 "$in" "${base}-page.png" 2>/dev/null \
        || die 1 "conversion failed — is '$in' a valid PDF?"
    local n; n="$(ls "${base}-page"*.png 2>/dev/null | grep -c . || true)"
    ok "produced ${n} PNG page(s): ${base}-page-*.png"
}

# ==================== HELP / GEN / SELFTEST =================================
usage() {
    cat <<DVK
docvert v$VERSION — image + document converter with PDF tools
ENGINES: ImageMagick · Ghostscript · pdftk · libreoffice (all optional per-task)

USAGE
  $SCRIPT_NAME image <files...> [options]     convert between png/jpg/webp/bmp/tiff/gif
  $SCRIPT_NAME pdf-merge <out.pdf> <a.pdf> <b.pdf> [...]
  $SCRIPT_NAME pdf-split <in.pdf> <1-3,5> <out.pdf>
  $SCRIPT_NAME pdf-rm    <in.pdf> <2,4>  <out.pdf>    remove pages, keep rest
  $SCRIPT_NAME to-pdf    <img|txt|md|html|docx>       anything → PDF
  $SCRIPT_NAME from-pdf  <in.pdf>                     PDF → PNG per page

IMAGE OPTIONS
  --to FMT     png|jpg|webp|bmp|tiff|gif   (required for image mode)
  --resize N%  or WxH                      (optional)
  -q N         quality 1-100               (default $QUALITY)
  -f           allow overwriting outputs

EXAMPLES
  $SCRIPT_NAME image *.png --to webp -q 80
  $SCRIPT_NAME image photo.jpg --to png --resize 50%
  $SCRIPT_NAME pdf-merge combined.pdf part1.pdf part2.pdf
  $SCRIPT_NAME pdf-split book.pdf 1-5 summary.pdf
  $SCRIPT_NAME pdf-rm scan.pdf 2,4 clean.pdf
  $SCRIPT_NAME to-pdf screenshot.png
  $SCRIPT_NAME from-pdf document.pdf

INSTALL ENGINES (only what you need):
  sudo apt install -y imagemagick        # images + to-pdf + from-pdf
  sudo apt install -y ghostscript poppler-utils pdftk   # pdf merge/split/rm
  sudo apt install -y wkhtmltopdf        # html → pdf
  sudo apt install -y libreoffice        # docx/odt → pdf (big)
DVK
}
gen_repo_files() {
    [[ -e README.md ]] || { cat > README.md <<'DV1'
# docvert

One bash script: **image converter**, **document converter**, and a small
**PDF toolbox** (merge / split / remove-pages). Wraps ImageMagick,
Ghostscript, pdftk and libreoffice with a consistent, safe CLI.

## commands

    ./docvert.sh image *.png --to webp -q 80        # batch convert + size report
    ./docvert.sh image photo.jpg --to png --resize 50%
    ./docvert.sh pdf-merge combined.pdf a.pdf b.pdf
    ./docvert.sh pdf-split book.pdf 1-5 summary.pdf
    ./docvert.sh pdf-rm scan.pdf 2,4 clean.pdf      # remove pages 2 and 4
    ./docvert.sh to-pdf screenshot.png              # images/txt/md/html/docx → pdf
    ./docvert.sh from-pdf document.pdf              # pdf → png per page

## safety design

- never overwrites input; existing outputs get -1, -2 suffixes (unless -f)
- verifies PDF inputs by header before touching them
- page ranges parsed strictly (1-5,8 style; bad specs rejected with examples)
- keeps originals always — conversions create NEW files

## engines (install only what you need)

    sudo apt install -y imagemagick                     # images
    sudo apt install -y ghostscript poppler-utils pdftk # pdf ops
    sudo apt install -y wkhtmltopdf                     # html→pdf
    sudo apt install -y libreoffice                     # docx/odt→pdf

## self-test (offline)

    ./docvert.sh --selftest

bash 4+, coreutils. Engines optional per feature. MIT licensed.
DV1
    printf '  [ok] README.md\n'; }
    [[ -e LICENSE ]] || { cat > LICENSE <<'DV2'
MIT License

Copyright (c) 2025 YOUR NAME HERE

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
DV2
    printf '  [ok] LICENSE (add your name!)\n'; }
    [[ -e requirements.txt ]] || { cat > requirements.txt <<'DV3'
# docvert — engine manifest (install only what you need)

# CORE
bash          (4.0+)   required
coreutils              required

# IMAGES (image / to-pdf / from-pdf)
imagemagick   required for image conversion   # provides `convert`

# PDF OPS (merge / split / pdf-rm)
ghostscript   required for pdf-merge          # provides `gs`
poppler-utils optional — page counting for pdf-rm
pdftk         optional — needed only for non-contiguous page sets (e.g. 1,3,7)

# DOCS (to-pdf extras)
enscript      optional — reliable txt/md → pdf
wkhtmltopdf   optional — html → pdf
libreoffice   optional (BIG) — docx/odt/pptx/xlsx → pdf

# ONE-LINE for full power:
# sudo apt install -y imagemagick ghostscript poppler-utils pdftk wkhtmltopdf enscript
DV3
    printf '  [ok] requirements.txt\n'; }
    [[ -e .gitignore ]] || { printf '*.pdf\n*.png\n*.jpg\n*.webp\n!README.md\n*.log\n.DS_Store\n' > .gitignore; printf '  [ok] .gitignore\n'; }
    printf '\nDone — edit LICENSE (your name), then upload.\n'
}
self_test() {
    local pass=0 fail=0 out tmp
    oks()  { printf '  %sPASS%s %s\n' "$GRN" "$R" "$1"; pass=$((pass+1)); }
    bads() { printf '  %sFAIL%s %s\n' "$RED" "$R" "$1"; fail=$((fail+1)); }
    printf '%sDOCVERT SELF-TEST (offline — temp folder only)%s\n' "$CYN" "$R"

    command -v convert > /dev/null 2>&1 && oks "imagemagick present" || bads "imagemagick missing (sudo apt install imagemagick)"
    command -v gs > /dev/null 2>&1 && oks "ghostscript present" || bads "ghostscript missing"
    check_pdftk && oks "pdftk present (full page ops)" || warn "pdftk missing — non-contiguous pages limited (info, not failure)"

    # page spec parser
    out="$(parse_pages '1-3,5' | tr '\n' ' ')"
    [[ "$out" == "1 2 3 5 " ]] && oks "page spec '1-3,5'" || bads "page spec ('$out')"
    out="$(parse_pages '7' | tr '\n' ' ')"
    [[ "$out" == "7 " ]] && oks "page spec '7'" || bads "page spec single"
    if parse_pages '5-1' > /dev/null 2>&1; then bads "reversed range rejected"; else oks "reversed range rejected"; fi
    if parse_pages 'abc' > /dev/null 2>&1; then bads "garbage range rejected"; else oks "garbage range rejected"; fi

    # smart_out collision behavior
    tmp="$(mktemp -d)"
    touch "$tmp/x.png"
    FORCE=0; out="$(smart_out "$tmp/x.png")"
    [[ "$out" == "$tmp/x-1.png" ]] && oks "collision suffix (-1)" || bads "collision suffix ($out)"
    FORCE=1; out="$(smart_out "$tmp/x.png")"
    [[ "$out" == "$tmp/x.png" ]] && oks "force overwrites" || bads "force"
    rm -rf "$tmp"

    # real round-trip if imagemagick exists
    if command -v convert > /dev/null 2>&1; then
        tmp="$(mktemp -d)"
        convert -size 30x20 xc:red "$tmp/a.png" 2>/dev/null
        TO_FMT="jpg"; QUALITY=85; RESIZE=""; FORCE=1
        CMD_FILES=("$tmp/a.png")
        if do_image > /dev/null 2>&1 && [[ -f "$tmp/a.jpg" ]]; then
            oks "png→jpg round-trip"
        else
            bads "png→jpg round-trip"
        fi
        rm -rf "$tmp"
    fi

    printf '%sRESULT: pass=%d fail=%d%s\n' "$CYN" "$pass" "$fail" "$R"
    (( fail > 0 )) && exit 1
    printf '%sSELF-TEST OK%s\n' "$GRN" "$R"
}

# ==================== CLI ===================================================
CMD_FILES=()
parse_args() {
    local mode=""
    local -a rest=()
    while (( $# > 0 )); do
        case "$1" in
            image) mode="image" ;;
            pdf-merge|pdf-split|pdf-rm|to-pdf|from-pdf) mode="$1" ;;
            --to) [[ -n "${2:-}" ]] || die 2 "--to needs a format"; TO_FMT="${2,,}"; shift ;;
            --resize) [[ -n "${2:-}" ]] || die 2 "--resize needs a value"; RESIZE="$2"; shift ;;
            -q) [[ "${2:-}" =~ ^[0-9]+$ ]] || die 2 "-q needs a number"; QUALITY="$2"; shift ;;
            -f|--force) FORCE=1 ;;
            --selftest) self_test; exit $? ;;
            --gen-files) gen_repo_files; exit 0 ;;
            -h|--help) usage; exit 0 ;;
            -V|--version) printf '%s v%s\n' "$SCRIPT_NAME" "$VERSION"; exit 0 ;;
            -*) die 2 "unknown option '$1' — try --help" ;;
            *) rest+=("$1") ;;
        esac
        shift
    done
    CMD_FILES=("${rest[@]:-}")
    case "$mode" in
        "") usage; echo; die 2 "pick a command: image | pdf-merge | pdf-split | pdf-rm | to-pdf | from-pdf" ;;
        image) do_image ;;
        pdf-merge)
            (( ${#CMD_FILES[@]} >= 3 )) || die 2 "pdf-merge: <out.pdf> <in1> <in2> [...]"
            do_pdf_merge "${CMD_FILES[0]}" "${CMD_FILES[@]:1}" ;;
        pdf-split)
            (( ${#CMD_FILES[@]} == 3 )) || die 2 "pdf-split: <in.pdf> <pages> <out.pdf>"
            do_pdf_split "${CMD_FILES[0]}" "${CMD_FILES[1]}" "${CMD_FILES[2]}" ;;
        pdf-rm)
            (( ${#CMD_FILES[@]} == 3 )) || die 2 "pdf-rm: <in.pdf> <pages-to-remove> <out.pdf>"
            do_pdf_rm "${CMD_FILES[0]}" "${CMD_FILES[1]}" "${CMD_FILES[2]}" ;;
        to-pdf)
            (( ${#CMD_FILES[@]} == 1 )) || die 2 "to-pdf: one file at a time"
            do_to_pdf "${CMD_FILES[0]}" ;;
        from-pdf)
            (( ${#CMD_FILES[@]} == 1 )) || die 2 "from-pdf: one file at a time"
            do_from_pdf "${CMD_FILES[0]}" ;;
    esac
}
parse_args "$@"
