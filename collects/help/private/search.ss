(module search mzscheme
  (require (lib "string-constant.ss" "string-constants")
           "docpos.ss"
           "colldocs.ss"
           "path.ss"
           (lib "list.ss"))
  
  (provide do-search
           doc-collections-changed)

  (define (html-doc-position x)
    (or (user-defined-doc-position x)
	(standard-html-doc-position x)))
  
  ; These are set by reset-doc-lists:
  ; docs, doc-names and doc-kinds are parallel lists. doc-kinds
  ; distinguishes between the two variants of docs.
  ; docs : (list-of (union string (list string string)))
  (define docs null)
  ; doc-names : (list-of string)
  (define doc-names null)
  ; doc-kinds : (list-of symbol)
  (define doc-kinds null)
  ; doc-collection-date : (union #f number 'none)
  (define doc-collection-date #f)
      
  (define re:title (regexp "<[tT][iI][tT][lL][eE]>(.*)</[tT][iI][tT][lL][eE]>"))
      
  ; get-std-doc-title : string -> string
  ; gets the standard title of the documentation, from the
  ; known docs list.
  (define (get-std-doc-title path doc)
    (cond
     [(string=? doc "help")
      "PLT Help Desk"]
     [(assoc doc known-docs)
      => (lambda (a) (cdr a))]
     [else
      (let ([index-file (build-path path doc "index.htm")])
	(if (file-exists? index-file)
	    (call-with-input-file index-file
	      (lambda (port)
		(let loop ()
		  (let ([l (read-line port)])
		    (cond
		     [(eof-object? l)
		      doc]
		     [(regexp-match re:title l)
		      =>
		      (lambda (m)
			(apply
			 string
			 (map (lambda (x) (if (char-whitespace? x) #\space x))
			      (string->list (cadr m)))))]
		     [else (loop)])))))
	    doc))]))
            
  (define (reset-doc-lists)
  ; Locate standard HTML documentation
    (define-values (std-docs std-doc-names)
      (let* ([path (with-handlers ([not-break-exn? (lambda (x) #f)])
				  (collection-path "doc"))])
	(if path
	    (let* ([doc-collections (directory-list path)]
		   [docs (map (lambda (x) (build-path path x)) doc-collections)]
               	   [doc-names (map (lambda (x) (get-std-doc-title path x)) doc-collections)])
		; Order the standard docs:
	      (let ([ordered (quicksort
			      (map list docs doc-collections doc-names)
			      (lambda (a b) ; html-doc-position expects collection name
				(< (html-doc-position (cadr a))
				   (html-doc-position (cadr b)))))])
		(values (map car ordered) (map caddr ordered)))) ; here we want the std title
	    (values null null))))
    
    ; Check collections for doc.txt files:
    (define-values (txt-docs txt-doc-names) (colldocs))
    
    (set! docs (append std-docs txt-docs))
    (set! doc-names (append
		     std-doc-names
		     (map (lambda (s) (format "the ~a collection" s))
			  txt-doc-names)))
    (set! doc-kinds (append (map (lambda (x) 'html) std-docs) (map (lambda (x) 'text) txt-docs)))
    
    (with-handlers ([not-break-exn?
		     (lambda (x) (set! doc-collection-date 'none))])
		   (set! doc-collection-date 
			 (file-or-directory-modify-seconds
			  (collection-path "doc")))))
  
  (define MAX-HIT-COUNT 300)
  
  (define (clean-html s)
    (regexp-replace*
     "&[^;]*;"
     (regexp-replace*
      "<[^>]*>"
      (regexp-replace* 
       "&amp;"
       (regexp-replace* 
	"&gt;"
	(regexp-replace*
	 "&lt;"
	 s
	 "<")
	">")
       "\\&")
      "")
     ""))
  
  ; One lock for all hash table operations is good enough
  (define ht-lock (make-semaphore 1))
  
  (define (with-hash-table ht key compute)
    (dynamic-wind
	(lambda () (semaphore-wait ht-lock))
	(lambda ()
	  (let ([sym (string->symbol key)])
	    (hash-table-get
	     ht
	     sym
	     (lambda ()
	       (let ([v (compute)])
		 (hash-table-put! ht sym v)
		 v)))))
	(lambda () (semaphore-post ht-lock))))
  
  (define html-keywords (make-hash-table))
  (define (load-html-keywords doc)
    (with-hash-table
     html-keywords
     doc
     (lambda ()
       (with-handlers ([not-break-exn? (lambda (x) null)])
		      (with-input-from-file (build-path doc "keywords")
			read)))))
      
  (define html-indices (make-hash-table))
  (define (load-html-index doc)
    (with-hash-table
     html-indices
     doc
     (lambda ()
       (with-handlers ([not-break-exn? (lambda (x) null)])
		      (with-input-from-file (build-path doc "hdindex")
			read)))))
      
  (define (parse-txt-file doc ht handle-one)
    (with-hash-table
     ht
     doc
     (lambda ()
       (with-handlers 
	([not-break-exn? (lambda (x) null)])
	(with-input-from-file doc
	  (lambda ()
	    (let loop ([start 0])
	      (let* ([r (read-line (current-input-port) 'any)]
		     [next (if (eof-object? r)
			       start
			       (+ start (string-length r) 1))])
		(cond
		 [(eof-object? r) null]
		 [(handle-one r start) => (lambda (vs) (append vs (loop next)))]
		 [else (loop next)])))))))))
  
  (define re:keyword-line (regexp "^>"))
  (define text-keywords (make-hash-table))
  (define (load-txt-keywords doc)
    (parse-txt-file
     (apply build-path doc)
     text-keywords
     (lambda (r start)
       (cond
	[(regexp-match re:keyword-line r)
	 (let* ([p (open-input-string (substring r 1 (string-length r)))]
		[entry (parameterize ([read-accept-bar-quote #f])
				     (read p))]
		[key (let loop ([entry entry])
		       (cond
			[(symbol? entry) entry]
			[(pair? entry) (if (eq? (car entry) 'quote)
					   (loop (cadr entry))
					   (loop (car entry)))]
			[else (error "bad entry")]))]
		[content (if (symbol? entry)
			     (with-handlers ([not-break-exn? (lambda (x) #f)])
					    (let ([s (read p)])
					      (if (eq? s '::)
						  (read p)
						  #f)))
			     #f)])
	   (list
            ; Make the keyword entry:
	    (list (symbol->string key) ; the keyword name
		  (let ([p (open-output-string)])
		    (if content
			(display content p)
			(if (and (pair? entry) 
				 (eq? (car entry) 'quote))
			    (fprintf p "'~s" (cadr entry))
			    (display entry p)))
		    (get-output-string p)) ; the text to display
		  (cadr doc) ; file
		  start ; label (a position in this case)
		  "doc.txt")))] ; title
	[else #f]))))
      
  (define re:index-line (regexp "_([^_]*)_(.*)"))
  (define text-indices (make-hash-table))
  (define (load-txt-index doc)
    (parse-txt-file
     (apply build-path doc)
     text-indices
     (lambda (r start)
       (cond
	[(regexp-match re:index-line r)
	 => (lambda (m)
	      (let loop ([m m])
		(let ([s (cadr m)])
		  (cons 
                   ; Make an index entry:
		   (cons s start)
		   (let ([m (regexp-match re:index-line (caddr m))])
		     (if m
			 (loop m)
			 null))))))]
	[else #f]))))
  
  (define re:splitter (regexp "^ *([^ ]+)(.*)"))
  (define (split-words s)
    (let ([m (regexp-match re:splitter s)])
      (if m
	  (cons (cadr m)
		(split-words (caddr m)))
	  null)))
      
  (define (non-regexp s)
    (list->string
     (apply
      append
      (map
       (lambda (c)
	 (cond 
	  [(memq c '(#\$ #\| #\\ #\[ #\] #\. #\* #\? #\+ #\( #\) #\^))
	   (list #\\ c)]
	  [(char-alphabetic? c)
	   (list #\[ (char-upcase c) (char-downcase c) #\])]
	  [else (list c)]))
       (string->list s)))))
      
  (define (doc-collections-changed)
    (set! doc-collection-date #f)
    (set! html-keywords (make-hash-table))
    (set! html-indices (make-hash-table))
    (set! text-keywords (make-hash-table))
    (set! text-indices (make-hash-table))
    (reset-doc-positions!))
      
  (define re:url-dir (regexp "^([^/]*)/(.*)$"))
  (define (combine-path/url-path path url-path)
    (let loop ([path path]
	       [url-path url-path])
      (cond
       [(regexp-match re:url-dir url-path)
	=>
	(lambda (m)
	  (let* ([url-dir (cadr m)]
		 [rest (caddr m)]
		 [dir
		  (cond
		   [(string=? ".." url-dir) 'up]
		   [(string=? "." url-dir) 'same]
		   [(string=? "" url-dir) 'same]
		   [else url-dir])])
	    (loop (build-path path dir)
		  rest)))]
       [else (build-path path url-path)])))

  
   (define max-reached #f)

   ; do-search : (string          ; the search text, unprocessed
      ;              num          ; 0 = keyword, 1 = keyword+index, 2 = all text
      ;              boolean      ; #t if string should be used as a regexp
      ;              boolean      ; #t if the string should match exactly (not just "contains")
      ;              value        ; arbitrary key supplied to the "add" functions
      ;              (-> A)       ; called when more than enough are found; must escape
      ;              (string value -> void) ; called to output a document section header (e.g., a manual name)
      ;              (symbol value -> void) ; called to output a document-kind section header, 'text or 'html
      ;              (string string string string (union string #f) value -> void)
      ;                ^       ^      ^     ^       ^- label within page
      ;                ^       ^      ^     ^- path to doc page
      ;                ^       ^      ^- source doc title
      ;                ^       ^- display label
      ;                ^- found entry's key 
      ;              ->
      ;              (union string #f))
      (define (do-search given-find search-level regexp? exact? ckey maxxed-out
                         add-doc-section add-kind-section add-choice)
        ; When new docs are installed, the directory's modification date changes:
        (set! max-reached #f)
        (unless (eq? doc-collection-date 'none)
          (when (or (not doc-collection-date)
                    (> (file-or-directory-modify-seconds (collection-path "doc"))
                       doc-collection-date))
            (reset-doc-lists)))
        (let* ([hit-count 0]
               [string-finds (list given-find)]
               [finds (cond
                        [exact? (list given-find)]
                        [regexp? (list (regexp given-find))]
                        [else (let ([wl (split-words given-find)])
                                (set! string-finds wl)
                                (map regexp (map non-regexp wl)))])])
          (for-each
           (lambda (doc doc-name doc-kind)
             (define found-one #f)
             (define (found kind)
	       (unless found-one
		       (add-doc-section doc-name ckey))
	       (unless (equal? found-one kind)
		       (set! found-one kind)
		       (add-kind-section kind ckey))
	       (set! hit-count (add1 hit-count))
	       (unless (< hit-count MAX-HIT-COUNT)
		       (maxxed-out)))
             
             ; Keyword search
             (let ([keys (case doc-kind
                           [(html) (load-html-keywords doc)]
                           [(text) (load-txt-keywords doc)]
                           [else null])]
                   [add-key-choice (lambda (v)
                                     (found "keyword entries")
                                     (add-choice
                                      (car v) ; key
                                      (cadr v) ; display
                                      (list-ref v 4) ; title
                                      (if (eq? 'text doc-kind)
                                          (apply build-path doc)
					  (let ([file (list-ref v 2)])
					    (if (servlet-path? file)
						file
						(build-path doc file))))
                                      (list-ref v 3) ; label
                                      ckey))])
               
               (unless regexp?
                 (for-each
                  (lambda (v)
                    (when (string=? given-find (car v))
                      (add-key-choice v)))
                  keys))
               (unless (or exact? (null? finds))
                 (for-each
                  (lambda (v)
                    (when (andmap (lambda (find) (regexp-match find (car v))) finds)
                      (unless (and (not regexp?) (string=? given-find (car v)))
                        (add-key-choice v))))
                  keys)))
             ; Index search
             (unless (< search-level 1)
               (let ([index (case doc-kind
                              [(html) (load-html-index doc)]
                              [(text) (load-txt-index doc)]
                              [else null])]
                     [add-index-choice (lambda (name desc)
                                         (case doc-kind
                                           [(html)
                                            (found "index entries")
                                            (add-choice 
					     "" name
					     (list-ref desc 2)
					     (let ([filename (list-ref desc 0)])
					       (if (servlet-path? filename)
						   filename
						   (combine-path/url-path doc filename)))
					     (list-ref desc 1)
					     ckey)]
                                           [(text)
                                            (found "index entries")
                                            (add-choice 
					     "" name
					     "indexed content"
					     (apply build-path doc)
					     desc
					     ckey)]))])
                 (when index
                   (unless regexp?
                     (for-each
                      (lambda (v)
                        (when (string=? given-find (car v))
                          (add-index-choice (car v) (cdr v))))
                      index))
                   (unless (or exact? (null? finds))
                     (for-each
                      (lambda (v)
                        (when (andmap (lambda (find) (regexp-match find (car v))) finds)
                          (unless (and (not regexp?) (string=? given-find (car v)))
                            (add-index-choice (car v) (cdr v)))))
                      index)))))
             ; Content Search
             (unless (or (< search-level 2) exact? (null? finds))
               (let ([files (case doc-kind
                              [(html) (with-handlers ([not-break-exn? (lambda (x) null)]) 
                                        (map (lambda (x) (build-path doc x)) 
                                             (filter
                                              (lambda (x) (file-exists? (build-path doc x)))
                                              (directory-list doc))))]
                              [(text) (list (apply build-path doc))]
                              [else null])])
                 (for-each
                  (lambda (f)
                    (with-handlers ([not-break-exn? (lambda (x) #f)])
                      (with-input-from-file f
                        (lambda ()
                          (let loop ()
                            (let ([pos (file-position (current-input-port))]
                                  [r (read-line)])
                              (unless (eof-object? r)
                                (let ([m (andmap (lambda (find) (regexp-match find r)) finds)])
                                  (when m
                                    (found "text")
                                    (add-choice (car m)
                                                ; Strip leading space and clean HTML
                                                (regexp-replace
                                                 "^ [ ]*"
                                                 (if (eq? doc-kind 'html)
                                                     (clean-html r)
                                                     r)
                                                 "")
                                                "content"
                                                f
                                                (if (eq? doc-kind 'text) pos "NO TAG")
                                                ckey)))
                                (loop))))))))
                  files))))
           docs doc-names doc-kinds)
          (if (= 0 hit-count)
	      (format (string-constant plt:hd:nothing-found-for)
                         (apply
                          string-append
			  (cons (format "\"~a\"" (car string-finds))
				(map (lambda (i) (format " ~a \"~a\"" (string-constant plt:hd:and) i))
				     (cdr string-finds)))))
              #f))))

