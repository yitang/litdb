;;; litdb.el --- litdb and emacs

;;; Commentary:
;; 
;; We define a new link: litdb
;; 
;; litdb:https://doi.org/10.1002/cssc.202200362
;;
;; These links are functional, and export to \cite commands in LaTeX, and you
;; can extract bibtex entries with `litdb-generate-bibtex'.
;;
;; You have to define where your db is `litdb-db' for now.
;;
;; `litdb-insert' selects entries by a citation string and inserts a link.
;; 
;; `litdb-fulltext' is an interactive function to do a full text search
;; 
;; `litdb-vsearch' is an interactive function to do a vector search
;; 
;; `litdb-gpt' is an interactive function to do a gpt query. This is quite slow
;; on my machine.

(require 'hydra)

;;; Code:

(defcustom litdb-db nil
  "Path to your litdb.")


;; * litdb link definition

(defface litdb-link-face
  `((t (:inherit org-link
                 :foreground "dark green")))
  "Color for litdb links.")


(org-link-set-parameters
 "litdb"
 :face 'litdb-link-face
 :activate-func #'litdb-activate
 :follow #'litdb-follow
 :help-echo #'litdb-tooltip
 :export #'litdb-export)


(defun litdb-export (path _desc backend)
  "Barest export function for PATH.
BACKEND is a symbol but only 'latex is supported, and only the simplest
cite command."
  (cond
   ((eq backend 'latex)
    (format "\\cite{%s}" path))

   (t
    (error "%s not supported yet." backend))))


(defun litdb-activate (start end path _bracketp)
  "Activation function for a litdb link
START and END are the bounds. PATH could be a comma-separated list."
  (let ((substrings (split-string path ","))
	(db (sqlite-open litdb-db)))
    (goto-char start)
    (cl-loop for path in substrings
	     do
	     (search-forward path end)
	     (put-text-property (match-beginning 0)
				(match-end 0)
				'litdb-key
				path)

	     (put-text-property (match-beginning 0)
				(match-end 0)
				'litdb
				(caar (sqlite-select db "select json_extract(extra, '$.citation'), source from sources where source = ?" (list path)))))))

(defun litdb-path-at-point ()
  "Return the path at point. Set in `litdb-activate'."
  (get-text-property (point) 'litdb-key))


(defhydra litdb-follow (:color blue :hint nil)
  "litdb actions
"
  ("o" (browse-url (litdb-path-at-point)) "Open")
  ("k" (kill-new (litdb-path-at-point)) "Copy source")
  ("c" (litdb-copy-citation (litdb-path-at-point))
   "Copy citation")
  ("b" (litdb-copy-bibtex (litdb-path-at-point))
   "Copy bibtex")
  ("a" (litdb-openalex (litdb-path-at-point)) "OpenAlex")
  ("s" (litdb-insert-similar (litdb-path-at-point)) "Insert related"))


(defun litdb-insert-similar (source)
  "Insert new entry similar to SOURCE by vector similarity.
This function is kind of slow because it uses the cli."
  (let* ((default-directory (file-name-directory litdb-db))
	 (candidates (read (shell-command-to-string
			    (format "litdb similar -n 10 -e \"%s\"" source)))))
    (ivy-read "Choose: " candidates
	      :action
	      '(1
		("o" (lambda (x)
		       ;; this is kind of dumb but the function takes a list,
		       ;; not a cons
		       (litdb-insert-candidate (list (car x)
						     (cdr x))))
		 "Insert")))))


(defun litdb-openalex (source)
  "Open source in OpenAlex."
  (interactive "sSource: ")
  (let* ((db (sqlite-open litdb-db)))
    (browse-url
     (caar
      (sqlite-select db "select json_extract(extra, '$.id') from sources where source = ?"
		     (list source))))))


(defun litdb-copy-citation (source)
  "Copy a citation for SOURCE."
  (interactive "sSource: ")
  (let* ((db (sqlite-open litdb-db)))
    (kill-new (caar (sqlite-select db "select json_extract(extra, '$.citation') from sources where source = ?"
				   (list source))))))


(defun litdb-copy-bibtex (source)
  "Copy a bibtex for SOURCE."
  (interactive "sSource: ")
  (let* ((db (sqlite-open litdb-db)))
    (kill-new (caar (sqlite-select db "select json_extract(extra, '$.bibtex') from sources where source = ?"
				   (list source))))))


(defun litdb-follow (_path)
  "Hydra for litdb-follow function"
  (interactive)
  (litdb-follow/body))


(defun litdb-tooltip (win _obj position)
  "Get the litdb tooltip at POSITION.
We use the citation from litdb. That might not exist for every entry.
Argument WIN The window."
  (interactive)
  (with-current-buffer (window-buffer win)
    (get-text-property position 'litdb)))


;; * Insert litdb links

(defvar litdb-insert-cache '(nil . nil)
  "Cache to use on candidates.
The car is a timestamp for when the cache was created. The cdr are the
candidates.")


(defun litdb-insert-candidates ()
  "Return the candidates to insert a link.
Use a cache if possible, and generate if not."
  (let* ((current-time (current-time))
	 (attributes (file-attributes litdb-db))
	 (db-mod-time (nth 5 attributes)))
    (if (time-less-p db-mod-time (car litdb-insert-cache))
	(cdr litdb-insert-cache)
      ;; generate cache
      (let* ((db (sqlite-open litdb-db))
	     (candidates (sqlite-select db "select json_extract(extra, '$.citation'), source from sources")))
	(setq litdb-insert-cache (cons current-time candidates))
	candidates))))


(defun litdb-insert-candidate (x)
  "Insert a link with X.
X is a candidate (citation source) as a list." 
  (cond
   ;; on a source in a link. add to end
   ((get-text-property (point) 'litdb)
    ;; go to end, insert source
    (goto-char (next-single-property-change (point) 'litdb))
    (insert (format ",%s" (nth 1 x))))

   ;; at the end of a link, one character past. this won't work for bracketed links
   ((get-text-property (- (point) 1) 'litdb)
    (insert (format ",%s" (nth 1 x))))

   ;; on the link type
   ((eq (get-text-property (point) 'face) 'litdb-link-face)
    (search-forward ":")
    (insert (format "%s," (nth 1 x))))

   ;; all other conditions I think we just insert a link.
   (t
    (insert (format "litdb:%s" (nth 1 x))))))


(defun litdb-insert ()
  "Insert a litdb link."
  (interactive)
  (let* ((db (sqlite-open litdb-db))
	 (candidates (litdb-insert-candidates)))
    
    (ivy-read "choose: " candidates
	      :caller 'litdb-insert
	      :action
	      '(1
		("o" litdb-insert-candidate "Insert link")))))


(defun litdb-display-transformer (candidate)
  "Prepare bib entry CANDIDATE for display.
This transformer allows org syntax in the candidate strings and wraps it to a nice length."
  (let* ((width (- (frame-width) 2))
	 (shr-width width)
	 (idx (get-text-property 1 'idx candidate))
	 (entry (cdr (nth idx (ivy-state-collection ivy-last)))))
    
    (with-temp-buffer 
      (insert
       (s-concat 
	(if (s-starts-with-p ivy-mark-prefix candidate)
	    ivy-mark-prefix "")
	candidate))
      
      (shr-render-region (point-min) (point-max))
      (string-trim-right (buffer-string)))))

(ivy-configure 'litdb-insert :display-transformer-fn #'litdb-display-transformer)

;; * Interactive functions to search / query
;;
;; These are not super fast functions. Maybe they could be faster if I was
;; running a local server. Right now they go through a shell command.

(defun litdb-fulltext (query N)
  "Do a fulltext search on QUERY. Defaults to a selected region, or prompts you.
N is a numeric prefix arg to set the number of entries to return. Default is 5.

Default action is insert link. Some other actions include:
- open the source
- insert bibtex
- insert citation"
  (interactive (list
		(if (region-active-p)
		    (buffer-substring-no-properties (region-beginning) (region-end))
		  (read-string "Query: "))
		current-prefix-arg))
  (let* ((N (or current-prefix-arg 5))
	 (db (sqlite-open litdb-db))
	 (results (sqlite-select db "select snippet(fulltext, 1, '', '', '', 64),source
    from fulltext
    where text match ? order by rank limit ?" (list query N))))
    (ivy-read "choose: " results
	      :action
	      '(1
		("o" (lambda (x)
		       "Insert a link."
		       (message "insert: %S" x)
		       (insert (format "litdb:%s" (nth 1 x))))
		 "insert link")
		("u" (lambda (x)
		       "Open the source. Assumes a url."
		       (message "open: %S" x)
		       (browse-url (nth 1 x)))
		 "Open source")
		("b" (lambda (x)
		       "Copy bibtex string."
		       (let* ((db (sqlite-open litdb-db))
			      (bibtex (caar (sqlite-select db "select json_extract(extra, '$.bibtex') from sources where source = ?" (list (nth 1 x))))))
			 
			 (kill-new bibtex)))
		 "Insert bibtex")
		("c" (lambda (x)
		       "Copy citation string."
		       (let* ((db (sqlite-open litdb-db))
			      (citation (caar (sqlite-select db "select json_extract(extra, '$.citation') from sources where source = ?" (list (nth 1 x))))))
			 
			 (kill-new citation)))
		 "Copy citation")))))


(defun litdb-vsearch (query N)
  "Do a vector search on litdb with QUERY. Defaults to selected region, or prompts you.
N is a numeric prefix arg for number of candidates to include. Default is 5.

This is not a fast function. It goes through the litdb cli command."
  (interactive (list
		(if (region-active-p)
		    (buffer-substring-no-properties (region-beginning) (region-end))
		  (read-string "Query: "))
		current-prefix-arg))
  (let* ((default-directory (file-name-directory litdb-db))
	 (N (or N 5))
	 (candidates (read (shell-command-to-string
			    (format "litdb vsearch -n %s -e \"%s\"" N query)))))
    
    (ivy-read "Choose: " candidates
	      :action
	      '(1
		("o" (lambda (x)
		       (insert (format "litdb:%s" (cdr x)))))
		("u" (lambda (x)
		       "Open the source. Assumes a url."
		       (message "open: %S" x)
		       (browse-url (cdr x)))
		 "Open source")
		("b" (lambda (x)
		       "Copy bibtex string."
		       (let* ((db (sqlite-open litdb-db))
			      (bibtex (caar (sqlite-select db "select json_extract(extra, '$.bibtex') from sources where source = ?" (list (cdr x))))))
			 
			 (kill-new bibtex)))
		 "Copy bibtex")
		("c" (lambda (x)
		       "Copy bibtex string."
		       (let* ((db (sqlite-open litdb-db))
			      (citation (caar (sqlite-select db "select json_extract(extra, '$.citation') from sources where source = ?" (list (cdr x))))))
			 
			 (kill-new citation)))
		 "Copy citation")))))


(defun litdb-gpt (query)
  "Run litdb gpt on the QUERY.

This is not a fast function. It goes through the litdb cli command, and
gpt is slow (it can be minutes to generate depending on what else the
computer is going. I don't have GPU acceleration on this. It is here as
a proof of concept.

This has potential for an async function."
  (interactive (list (if (region-active-p)
			 (buffer-substring-no-properties (region-beginning) (region-end))
		       (read-string "Query: "))))
  (let* ((default-directory (file-name-directory litdb-db))
	 (output (shell-command-to-string
		  (format "litdb gpt \"%s\"" query)))
	 (buf (get-buffer-create "*litdb-gpt*")))
    (with-current-buffer buf
      (erase-buffer)
      (insert output)
      (org-mode))
    (pop-to-buffer buf)
    (goto-char (point-min))))



;; * extract entries to bibtex

(defun litdb-generate-bibtex (bibtex-file)
  "Parse the org-buffer, collect litdb links, and create a bibtex file from them.

Note it is not certain all the bibtex entries are correct and valid.
Notably, the DOI or OpenAlex id is used as a key, and almost certainly
some of these are invalid."
  (interactive "fBibtex file: ")

  ;; get all the paths
  (let* ((db (sqlite-open litdb-db))
	 (sources (org-element-map (org-element-parse-buffer) 'link
		    (lambda (link)
		      (let ((plist (nth 1 link))
			    (keys '()))
			(when (string= "litdb" (plist-get plist ':type))
			  (setq keys (append keys (org-element-property :path link))))))))
	 ;; look up bibtex entries. In theory this is ok, but the entries don't
	 ;; have the right key to match right now.
	 (bibtex-entries (cl-loop for source in sources
				  collect
				  (caar (sqlite-select db "select json_extract(extra, '$.bibtex') from sources where source = ?" (list source))))))

    (with-temp-file bibtex-file
      (insert (string-join bibtex-entries "\n")))))


(provide 'litdb)

;;; litdb.el ends here
