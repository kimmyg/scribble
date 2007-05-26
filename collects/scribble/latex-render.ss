
(module latex-render mzscheme
  (require "struct.ss"
           (lib "class.ss"))
  (provide render-mixin)

  (define current-table-depth (make-parameter 0))
  (define rendering-tt (make-parameter #f))

  (define-struct (toc-paragraph paragraph) ())

  (define (render-mixin %)
    (class %
      (define/override (get-suffix) #".tex")

      (inherit render-flow
               render-content
               install-file)

      (define (define-color s s2)
        (printf "\\newcommand{\\~a}[1]{{\\texttt{\\color{~a}{#1}}}}\n" s s2))

      (define/override (render-one d ht fn)
        (printf "\\documentclass{article}\n")
        (printf "\\parskip=10pt%\n")
        (printf "\\parindent=0pt%\n")
        (printf "\\usepackage{graphicx}\n")
        (printf "\\renewcommand{\\rmdefault}{ptm}\n")
        ;; (printf "\\usepackage{fullpage}\n")
        (printf "\\usepackage{longtable}\n")
        (printf "\\usepackage[usenames,dvipsnames]{color}\n")
        (define-color "schemeplain" "black")
        (printf "\\newcommand{\\schemekeyword}[1]{{\\color{black}{\\texttt{\\textbf{#1}}}}}\n")
        (printf "\\newcommand{\\schemesyntaxlink}[1]{\\schemekeyword{#1}}\n")
        (define-color "schemecomment" "Brown")
        (define-color "schemeparen" "BrickRed")
        (define-color "schemeinputcol" "BrickRed")
        (define-color "schemesymbol" "NavyBlue")
        (define-color "schemevalue" "ForestGreen")
        (define-color "schemevaluelink" "blue")
        (define-color "schemeresult" "NavyBlue")
        (define-color "schemestdout" "Purple")
        (define-color "schemevariablecol" "NavyBlue")
        (printf "\\newcommand{\\schemevariable}[1]{{\\schemevariablecol{\\textsl{#1}}}}\n")
        (define-color "schemeerrorcol" "red")
        (printf "\\newcommand{\\schemeerror}[1]{{\\schemeerrorcol{\\textrm{\\textit{#1}}}}}\n")
        (printf "\\newcommand{\\schemeopt}[1]{#1}\n")
        (printf "\\newcommand{\\textsub}[1]{$_{#1}$}\n")
        (printf "\\newcommand{\\textsuper}[1]{$^{#1}$}\n")
        (printf "\\newcommand{\\refcontent}[1]{#1}\n")
        (printf "\\definecolor{LightGray}{rgb}{0.90,0.90,0.90}\n")
        (printf "\\newcommand{\\schemeinput}[1]{\\colorbox{LightGray}{\\hspace{-0.5ex}\\schemeinputcol{#1}\\hspace{-0.5ex}}}\n")
        (printf "\\begin{document}\n")
        (when (part-title-content d)
          (printf "\\title{")
          (render-content (part-title-content d) d ht)
          (printf "}\\maketitle\n"))
        (render-part d ht)
        (printf "\\end{document}\n"))

      (define/override (render-part d ht)
        (let ([number (collected-info-number (part-collected-info d))])
          (when (and (part-title-content d)
                     (pair? number))
            (printf "\\~a~a{"
                    (case (length number)
                      [(0 1) "section"]
                      [(2) "subsection"]
                      [(3) "subsubsection"]
                      [else "subsubsection*"])
                    (if (and (pair? number)
                             (not (car number)))
                        "*"
                        ""))
            (render-content (part-title-content d) d ht)
            (printf "}"))
          (when (part-tag d)
            (printf "\\label{section:~a}" (part-tag d)))
          (render-flow (part-flow d) d ht)
          (for-each (lambda (sec) (render-part sec ht))
                    (part-parts d))
          null))
      
      (define/override (render-paragraph p part ht)
        (printf "\n\n")
        (if (toc-paragraph? p)
            (printf "\\newpage \\tableofcontents \\newpage")
            (super render-paragraph p part ht))
        (printf "\n\n")
        null)

      (define/override (render-element e part ht)
        (when (and (link-element? e)
                   (pair? (link-element-tag e))
                   (eq? 'part (car (link-element-tag e)))
                   (null? (element-content e)))
          (printf "\\S\\ref{section:~a} " (cadr (link-element-tag e))))
        (let ([style (and (element? e)
                          (element-style e))]
              [wrap (lambda (e s tt?)
                      (printf "{\\~a{" s)
                      (parameterize ([rendering-tt (or tt?
                                                       (rendering-tt))])
                        (super render-element e part ht))
                      (printf "}}"))])
          (cond
           [(symbol? style)
            (case style
              [(italic) (wrap e "textit" #f)]
              [(bold) (wrap e "textbf" #f)]
              [(tt) (wrap e "texttt" #t)]
              [(sf) (wrap e "textsf" #f)]
              [(subscript) (wrap e "textsub" #f)]
              [(superscript) (wrap e "textsuper" #f)]
              [(hspace) (let ([s (content->string (element-content e))])
                          (case (string-length s)
                            [(0) (void)]
                            [(1) (printf "{\\texttt{ }}")] ; allows a line break to replace the space
                            [else
                             (printf "{\\texttt{~a}}"
                                     (regexp-replace* #rx"." s "~"))]))]
              [else (error 'latex-render "unrecognzied style symbol: ~s" style)])]
           [(string? style)
            (wrap e style (regexp-match? #px"^scheme(?!error)" style))]
           [(image-file? style) 
            (let ([fn (install-file (image-file-path style))])
              (printf "\\includegraphics{~a}" fn))]
           [else (super render-element e part ht)]))
        null)

      (define/override (render-table t part ht)
        (let* ([boxed? (eq? 'boxed (table-style t))]
               [index? (eq? 'index (table-style t))]
               [tableform (cond
                           [index? "theindex"]
                           [(zero? (current-table-depth))
                            "longtable"]
                           [else "tabular"])]
               [opt (if (zero? (current-table-depth))
                        "[l]"
                        "")])
          (unless (null? (table-flowss t))
            (parameterize ([current-table-depth (add1 (current-table-depth))])
              (if index?
                  (printf "\n\n\\begin{theindex}\n")
                  (printf "\n\n~a\\begin{~a}~a{@{}~a}\n"
                          (if boxed? "\\vspace{4ex}\\hrule\n\\vspace{-2ex}\n" "")
                          tableform
                          opt
                          (apply string-append
                                 (map (lambda (i) "l@{}")
                                      (car (table-flowss t))))))
              (for-each (lambda (flows)
                          (let loop ([flows flows])
                            (unless (null? flows)
                              (render-flow (car flows) part ht)
                              (unless (null? (cdr flows))
                                (printf " &\n")
                                (loop (cdr flows)))))
                          (unless index?
                            (printf " \\\\\n")))
                        (table-flowss t))
              (printf "\n\n\\end{~a}~a\n" 
                      tableform
                      (if (equal? tableform "longtable")
                          "\\vspace{-3ex}" ;; counteracts mysterious space added after longtable
                          "")))))
        null)

      (define/override (render-itemization t part ht)
        (printf "\n\n\\begin{itemize}\n")
        (for-each (lambda (flow)
                    (printf "\n\n\\item ")
                    (render-flow flow part ht))
                  (itemization-flows t))
        (printf "\n\n\\end{itemize}\n")
        null)

      (define/override (render-other i part ht)
        (cond
         [(string? i) (display-protected i)]
         [(symbol? i) (display
                       (case i
                         [(nbsp) "~"]
                         [(mdash) "---"]
                         [(ndash) "--"]
                         [(ldquo) "``"]
                         [(rdquo) "''"]
                         [(rsquo) "'"]
                         [(rarr) "$\\rightarrow$"]))]
         [else (display-protected (format "~s" i))])
        null)

      (define/private (display-protected s)
        (let ([len (string-length s)])
          (let loop ([i 0])
            (unless (= i len)
              (let ([c (string-ref s i)])
                (case c
                  [(#\\) (display "$\\backslash$")]
                  [(#\_) (display "$\\_$")]
                  [(#\>) (if (rendering-tt)
                             (display "{\\texttt >}")
                             (display "$>$"))]
                  [(#\<) (if (rendering-tt)
                             (display "{\\texttt <}")
                             (display "$<$"))]
                  [(#\? #\! #\. #\:) (if (rendering-tt)
                                         (printf "{\\hbox{\\texttt{~a}}}" c)
                                         (display c))]
                  [(#\~) (display "$\\sim$")]
                  [(#\{ #\} #\# #\% #\&) (display "\\") (display c)]
                  [(#\uDF) (display "{\\ss}")]
                  [(#\u039A) (display "K")] ; kappa
                  [(#\u0391) (display "A")] ; alpha
                  [(#\u039F) (display "O")] ; omicron
                  [(#\u03A3) (display "$\\Sigma$")]
                  [(#\u03BA) (display "$\\kappa$")]
                  [(#\u03B1) (display "$\\alpha$")]
                  [(#\u03BF) (display "o")] ; omicron
                  [(#\u03C3) (display "$\\sigma$")]
                  [(#\u03BB) (display "$\\lambda$")]
                  [(#\u03BC) (display "$\\mu$")]
                  [else (display c)]))
              (loop (add1 i))))))
                  
      ;; ----------------------------------------

      (define/override (table-of-contents sec ht)
        ;; FIXME: isn't local to the section
        (make-toc-paragraph null))

      (define/override (local-table-of-contents part ht)
        (make-paragraph null))

      ;; ----------------------------------------

      (super-new))))