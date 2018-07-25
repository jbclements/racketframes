;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;*    Author: Shubham Kahal
;*    File: data-frame-join.rkt
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

#lang typed/racket
(require math/statistics)

; ***********************************************************
; data-frame-join rough draft, currently joins are only possible
; on integer and categorical series
; ***********************************************************

; ***********************************************************
; Provide functions in this file to other files.
(provide:
 [data-frame-join-left (DataFrame DataFrame [#:on (Listof Symbol)] -> DataFrame)]
 [data-frame-join-right (DataFrame DataFrame [#:on (Listof Symbol)] -> DataFrame)]
 [data-frame-join-inner (DataFrame DataFrame [#:on (Listof Symbol)] -> DataFrame)]
 [data-frame-join-outer (DataFrame DataFrame [#:on (Listof Symbol)] -> DataFrame)]
 [copy-column-row-error (Series Integer -> Void)]
 [copy-column-row ((Vectorof Series) (Vectorof SeriesBuilder) Index -> Void)]
 [dest-mapping-series-builders (DataFrameDescription Index -> (Listof SeriesBuilder))]
 [join-column-name (Column (Setof Label) String -> Symbol)]
 [build-multi-index-from-cols ((U (Listof IndexableSeries) Columns) -> SIndex)])

(provide
 IndexableSeries)

(require
 racket/pretty
 racket/unsafe/ops
 racket/flonum
 racket/set
 (only-in racket/set
          set set-member?
	  list->set set->list
	  set-intersect set-subtract)
 (only-in "../util/symbol.rkt"
          symbol-prefix)
 (only-in "indexed-series.rkt"
	  SIndex Label Labeling LabelProjection)
 (only-in "series.rkt"
	  series-complete)
 (only-in "series-description.rkt"
	  SeriesType Series
	  SeriesDescription-type
	  series-type series-length
          series-data series-iref)
 (only-in "data-frame.rkt"
	  DataFrame Column Columns Columns? new-data-frame data-frame-names
	  data-frame-cseries data-frame-explode
	  DataFrameDescription DataFrameDescription-series data-frame-description)
 (only-in "generic-series.rkt"
	  GenSeries GenSeries? GenericType gen-series-iref new-GenSeries
	  gen-series-referencer)
 (only-in "numeric-series.rkt"
	  NSeries NSeries? nseries-iref nseries-label-ref new-NSeries
          nseries-referencer)
 (only-in "integer-series.rkt"
	  ISeries ISeries? iseries-iref new-ISeries
	  iseries-referencer)
 (only-in "boolean-series.rkt"
	  BSeries BSeries? bseries-iref new-BSeries
	  bseries-referencer)
 (only-in "categorical-series.rkt"
	  cseries-referencer cseries-length cseries-iref
	  CSeries CSeries? new-CSeries)
 (only-in "series-builder.rkt"
	  SeriesBuilder)
 (only-in "generic-series-builder.rkt"
	  GenSeriesBuilder GenSeriesBuilder?
	  append-GenSeriesBuilder complete-GenSeriesBuilder
	  new-GenSeriesBuilder)
 (only-in "integer-series-builder.rkt"
	  ISeriesBuilder ISeriesBuilder?
	  append-ISeriesBuilder complete-ISeriesBuilder
	  new-ISeriesBuilder)
 (only-in "boolean-series-builder.rkt"
	  BSeriesBuilder BSeriesBuilder?
	  append-BSeriesBuilder complete-BSeriesBuilder
	  new-BSeriesBuilder)
 (only-in "categorical-series-builder.rkt"
	  CSeriesBuilder CSeriesBuilder?
	  append-CSeriesBuilder complete-CSeriesBuilder
	  new-CSeriesBuilder)
 (only-in "categorical-series-ops.rkt"
	  cseries-append)
 (only-in "numeric-series-builder.rkt"
	  NSeriesBuilder NSeriesBuilder?
	  append-NSeriesBuilder complete-NSeriesBuilder
	  new-NSeriesBuilder)
 (only-in "data-frame-print.rkt"
          data-frame-write-tab))

; ***********************************************************

; ***********************************************************

(define-type Key String)
(define-type JoinHash (HashTable Key (Listof Index)))
(define-type GroupHash (HashTable Key (Listof GenericType)))
(define-type AggValueHash (HashTable String GenericType))
(define-type IndexableSeries (U GenSeries CSeries ISeries))

(define-predicate ListofReal? (Listof Real))

(define key-delimiter "\t")

; ***********************************************************

; ***********************************************************

; This function consumes a Column and returns the series of
; the Column which is just the second element of the list.
(: column-series (Column -> Series))
(define (column-series scol)
  (cdr scol))

; This function consumes a Column, Setof Label and String
; and checks if the column name of Column is a member of the
; given Setof Label, and if it is, it prepends the prefix
; to the column name and returns that new value. Used for
; join column names.
(: join-column-name (Column (Setof Label) String -> Symbol))
(define (join-column-name column common-cols prefix)
  (let ((colname (car column)))
    (if (set-member? common-cols colname)
	(symbol-prefix colname prefix)
	colname)))

; ***********************************************************

; ***********************************************************

; This function consumes a DataFrameDescription and an Index
; and returns new default series builders of the the given
; length. There will be as many series as there are in the
; DataFrameDecsription.
(: dest-mapping-series-builders (DataFrameDescription Index -> (Listof SeriesBuilder)))
(define (dest-mapping-series-builders data-frame-description len)
  (for/list: : (Listof SeriesBuilder)
	     ([series (DataFrameDescription-series data-frame-description)])
	     (case (SeriesDescription-type series)
               ((GenericSeries)     (new-GenSeriesBuilder len))
	       ((CategoricalSeries) (new-CSeriesBuilder len))
	       ((NumericSeries)     (new-NSeriesBuilder len))
	       ((IntegerSeries)     (new-ISeriesBuilder len))
	       (else (error 'dest-mapping-series-builders
			    "Unknown series type ~a."
			    (SeriesDescription-type series))))))

; ***********************************************************

; ***********************************************************

; This function consumes a Listof Columns and alphabetically
; sorts it on the column name and returns new sorted list.
(: key-cols-sort-lexical (Columns -> Columns))
(define (key-cols-sort-lexical cols)
  ((inst sort Column Column)
   cols
   (λ: ((kc1 : Column) (kc2 : Column))
       (string<=? (symbol->string (car kc1))
		  (symbol->string (car kc2))))))

; This function consumes a Listof Column and filteres it for
; only columns of CSeries or ISeries and returns those series
; in list form.
(: key-cols-series (Columns -> (Listof IndexableSeries)))
(define (key-cols-series cols)
  (filter (λ: ((s : Series)) (or (GenSeries? s)
                              (CSeries? s)
                              (ISeries? s)))
	  (map column-series cols)))

; This function consumes a Listof IndexableSeries and builds key
; string from the columns of a frame and a given set of col labels to use.
; Insert a tab char between each key value, e.g., k1 + \t + k2 + \t + ...
(: key-fn ((Listof IndexableSeries) -> (Index -> Key)))
(define (key-fn cols)
  (let: ((col-refs : (Listof (Index -> GenericType))
		   (for/list ([col (in-list cols)])
                     (if (GenSeries? col)
                         (gen-series-referencer col)
			     (if (CSeries? col)
				 (cseries-referencer col)
				 (iseries-referencer col))))))
	(λ: ((row-id : Index))
	    (let ((outp (open-output-string)))
	      (for ([col-ref (in-list col-refs)])
		   (let*: ((seg : GenericType (col-ref row-id))
			   (seg-str : String (cond
                                               [(symbol? seg) (symbol->string seg)]
                                               [(number? seg) (number->string seg)]
                                               ; pretty-format anything else
                                               [else (pretty-format seg)])))
                     (display seg-str outp)
                     (display key-delimiter outp)))
              (get-output-string outp)))))

; ***********************************************************

; ***********************************************************

; This function is self-explanatory, it consumes no arguments
; and creates a hash map which will represent a JoinHash.
(: make-index (-> JoinHash))
(define (make-index)
  (make-hash))

; This function consumes a Listof IndexableSeries and creates
; a JoinHash.
(: index ((Listof IndexableSeries) -> JoinHash))
(define (index cols)

  (define: index : JoinHash (make-index))

  ; Get length of one of the IndexableSeries
  (define len (series-length (car cols)))
  (define: series-key : (Index -> String) (key-fn cols))

  (let loop ([i 0])
    (if (unsafe-fx>= i len)
	index
	(let: ((i : Index (assert i index?)))
	      (let ((key (series-key i)))
		(hash-update! index key
			      (λ: ((idx : (Listof Index)))
				  (cons i idx))
			      (λ () (list))))
	      (loop (add1 i))))))

; ***********************************************************

; ***********************************************************

; This function consumes a CSeries and a CSeriesBuilder and
; returns a function which consumes an index which indexes into
; the CSeries and retrieves the item to append onto the
; CSeriesBuilder.
(: cseries-copy-fn (CSeries CSeriesBuilder -> (Index -> Void)))
(define (cseries-copy-fn series builder)
  (let ((cseries-ref (cseries-referencer series)))
    (λ: ((i : Index))
	(append-CSeriesBuilder builder (cseries-ref i)))))

; This function consumes an ISeries and a ISeriesBuilder and
; returns a function which consumes an index which indexes into
; the ISeries and retrieves the item to append onto the
; ISeriesBuilder.
(: iseries-copy-fn (ISeries ISeriesBuilder -> (Index -> Void)))
(define (iseries-copy-fn series builder)
  (let ((iseries-ref (iseries-referencer series)))
    (λ: ((i : Index))
	(append-ISeriesBuilder builder (iseries-ref i)))))

; This function consumes an NSeries and a NSeriesBuilder and
; returns a function which consumes an index which indexes into
; the NSeries and retrieves the item to append onto the
; NSeriesBuilder.
(: nseries-copy-fn (NSeries NSeriesBuilder -> (Index -> Void)))
(define (nseries-copy-fn series builder)
  (let ((nseries-ref (nseries-referencer series)))
    (λ: ((i : Index))
	(append-NSeriesBuilder builder (nseries-ref i)))))

; This function consumes an ISeries and a ISeriesBuilder and
; returns a function which consumes an index which indexes into
; the ISeries and retrieves the item to append onto the
; ISeriesBuilder.
(: gen-series-copy-fn (GenSeries GenSeriesBuilder -> (Index -> Void)))
(define (gen-series-copy-fn series builder)
  (let ((gen-series-ref (gen-series-referencer series)))
    (λ: ((i : Index))
	(append-GenSeriesBuilder builder (gen-series-ref i)))))

; This function consumes an BSeries and a BSeriesBuilder and
; returns a function which consumes an index which indexes into
; the BSeries and retrieves the item to append onto the
; BSeriesBuilder.
(: bseries-copy-fn (BSeries BSeriesBuilder -> (Index -> Void)))
(define (bseries-copy-fn series builder)
  (let ((bseries-ref (bseries-referencer series)))
    (λ: ((i : Index))
	(append-BSeriesBuilder builder (bseries-ref i)))))

; This function is self explanatory, returns a formated error
; on a copy column row error.
(: copy-column-row-error (Series Integer -> Void))
(define (copy-column-row-error series col)
  (error 'data-frame-join "Invalid target builder for data-frame column series ~s at ~s"
	 (series-type series) col))

; This functions consumes a Vectorof Series and Vectorof SeriesBuilder
; and an Index and does not return any value. It copies an entire row
; from the given Vectorof Series into the given Vectorof SeriesBuilders.
(: copy-column-row ((Vectorof Series) (Vectorof SeriesBuilder) Index -> Void))
(define (copy-column-row src-series dest-builders row-id)
;;  (when (zero? (modulo row-id 10000))
;;	(displayln (format "Copy row: ~a" row-id)))
  (for ([col (in-range (vector-length src-series))])
    ; Loop through each column and get the associated series and series builder.
       (let ((series (vector-ref src-series col))
	     (builder (vector-ref dest-builders col)))
         ; Copy specific row values into correct series builders. If series is
         ; a NSeries then associated value will be appended onto NSeriesBuilder,
         ; and same goes for ISeries and CSeries.
         (cond
           ((GenSeries? series)
            (let: ((val : GenericType (gen-series-iref series (list row-id))))
              (if (GenSeriesBuilder? builder)
                  (append-GenSeriesBuilder builder (car (assert val list?)))
                  (copy-column-row-error series col))))
           ((NSeries? series)
            (let: ((num : Float (car (nseries-iref series (list row-id)))))
              (if (NSeriesBuilder? builder)
                  (append-NSeriesBuilder builder num)
                  (copy-column-row-error series col))))
           ((CSeries? series)
            (let: ((nom : Label (car (cseries-iref series (list row-id)))))
              (if (CSeriesBuilder? builder)
                  (append-CSeriesBuilder builder nom)
                  (copy-column-row-error series col))))
           ((ISeries? series)
            (let: ((num : Fixnum (car (iseries-iref series (list row-id)))))
              (if (ISeriesBuilder? builder)
                  (append-ISeriesBuilder builder num)
                  (copy-column-row-error series col))))))))

; This functions consumes a Vectorof Series and Vectorof SeriesBuilder
; and an Index and does not return any value. It copies an entire row
; from the given Vectorof Series into the given Vectorof SeriesBuilders.
(: copy-null-to-row ((Vectorof Series) (Vectorof SeriesBuilder) -> Void))
(define (copy-null-to-row src-series dest-builders)
;;  (when (zero? (modulo row-id 10000))
;;	(displayln (format "Copy row: ~a" row-id)))
  (for ([col (in-range (vector-length src-series))])
    ; Loop through each column and get the associated series and series builder.
       (let ((series (vector-ref src-series col))
	     (builder (vector-ref dest-builders col)))
         ; Copy specific row values into correct series builders. If series is
         ; a NSeries then associated value will be appended onto NSeriesBuilder,
         ; and same goes for ISeries and CSeries.
         (cond
           ((GenSeries? series)
            (if (GenSeriesBuilder? builder)
                (append-GenSeriesBuilder builder 'null)
                (copy-column-row-error series col)))
           ((CSeries? series)
            (if (CSeriesBuilder? builder)
                (append-CSeriesBuilder builder 'null)
                (copy-column-row-error series col)))
           ((ISeries? series)
            (if (ISeriesBuilder? builder)
                (append-ISeriesBuilder builder 0)
                (copy-column-row-error series col)))
           ((NSeries? series)
            (if (NSeriesBuilder? builder)
                (append-NSeriesBuilder builder +nan.0)
                (copy-column-row-error series col)))))))

; ***********************************************************

; ***********************************************************

; This function consumes two Vectorof Series and two Vectorof
; SeriesBuilder. The types of Series and SeriesBuilder must
; match in the respective indicies.
(: do-join-build-left/right ((Vectorof Series) (Vectorof Series) (Vectorof Series)
		  (Vectorof SeriesBuilder) (Vectorof SeriesBuilder)
		  (Index -> Key) JoinHash -> Void))
(define (do-join-build-left/right a-cols b-cols b-cols-match a-builders b-builders dfa-key-fn join-hash)

  (define: a-col-cnt : Fixnum (vector-length a-cols))
  (define: b-col-cnt : Fixnum (vector-length b-cols))
  (define: dfa-len   : Fixnum (series-length (vector-ref a-cols #{0 : Index} )))

  (for ((dfa-row (in-range dfa-len)))
       (let*: ((dfa-row : Index (assert dfa-row index?))
	       (dfa-key : Key (dfa-key-fn dfa-row)))
	      (let ((dfb-rows (hash-ref join-hash dfa-key (λ () '()))))
                ;(displayln (format "Hash join: ~s ~s, ~s" dfa-row dfa-key dfb-rows))
                (if (null? dfb-rows)
                    (begin (copy-column-row a-cols a-builders dfa-row)
                    ; Copy nans into fb
                    (copy-null-to-row b-cols b-builders))
                    ;(copy-null-to-row b-cols-match b-builders))
                    (for ([dfb-row dfb-rows])
                      ; maps possible multiple rows from b to row in a
                      (copy-column-row a-cols a-builders dfa-row)
                      (copy-column-row b-cols b-builders (assert dfb-row index?))))))))

; ***********************************************************

; ***********************************************************

; This function consumes two Vectorof Series and two Vectorof
; SeriesBuilder. The types of Series and SeriesBuilder must
; match in the respective indicies.
(: do-join-build-inner ((Vectorof Series) (Vectorof Series)
		  (Vectorof SeriesBuilder) (Vectorof SeriesBuilder)
		  (Index -> Key) JoinHash -> Void))
(define (do-join-build-inner a-cols b-cols a-builders b-builders dfa-key-fn join-hash)

  (define: a-col-cnt : Fixnum (vector-length a-cols))
  (define: b-col-cnt : Fixnum (vector-length b-cols))
  (define: dfa-len   : Fixnum (series-length (vector-ref a-cols #{0 : Index} )))

  (for ((dfa-row (in-range dfa-len)))
       (let*: ((dfa-row : Index (assert dfa-row index?))
	       (dfa-key : Key (dfa-key-fn dfa-row)))
	      (let ((dfb-rows (hash-ref join-hash dfa-key (λ () '()))))                
                (for ([dfb-row dfb-rows])
                  ; maps possible multiple rows from b to row in a
                  (copy-column-row a-cols a-builders dfa-row)
                  (copy-column-row b-cols b-builders (assert dfb-row index?)))))))

; ***********************************************************

; ***********************************************************

; This function consumes two Vectorof Series and two Vectorof
; SeriesBuilder. The types of Series and SeriesBuilder must
; match in the respective indicies.
(: do-join-build-outer ((Vectorof Series) (Vectorof Series)
		  (Vectorof SeriesBuilder) (Vectorof SeriesBuilder)
		  (Index -> Key) (Index -> Key) JoinHash JoinHash -> Void))
(define (do-join-build-outer a-cols b-cols a-builders b-builders dfa-key-fn dfb-key-fn join-hash-a join-hash-b)

  (define: a-col-cnt : Fixnum (vector-length a-cols))
  (define: b-col-cnt : Fixnum (vector-length b-cols))
  (define: dfa-len   : Fixnum (series-length (vector-ref a-cols #{0 : Index} )))
  (define: dfb-len   : Fixnum (series-length (vector-ref b-cols #{0 : Index} )))

  (define: joined-key-set : (Setof Key) (set))

  ; do for a
  (for ((dfa-row (in-range dfa-len)))
       (let*: ((dfa-row : Index (assert dfa-row index?))
               (dfa-key : Key (dfa-key-fn dfa-row)))
         
         (set! joined-key-set (set-add joined-key-set dfa-key))
         (let ((dfb-rows (hash-ref join-hash-b dfa-key (λ () '()))))
           ;(displayln (format "Hash join A: ~s ~s, ~s" dfa-row dfa-key dfb-rows))
           (if (null? dfb-rows)                    
               (begin
                 ; copy a value but null for b
                 (copy-column-row a-cols a-builders dfa-row)
                 (copy-null-to-row b-cols b-builders))
               (for ([dfb-row dfb-rows])
                 ; maps possible multiple rows from b to row in a                      
                 (copy-column-row a-cols a-builders dfa-row)
                 (copy-column-row b-cols b-builders (assert dfb-row index?)))))))

  ; do vice versa for b
  (for ((dfb-row (in-range dfb-len)))
       (let*: ((dfb-row : Index (assert dfb-row index?))
               (dfb-key : Key (dfb-key-fn dfb-row)))         
         (when (not (subset? (set dfb-key) joined-key-set))
	      (let ((dfa-rows (hash-ref join-hash-a dfb-key (λ () '()))))
                ;(displayln (format "Hash join B: ~s ~s, ~s" dfb-row dfb-key dfa-rows))
                (if (null? dfa-rows)                    
                    (begin
                      ; copy a value but null for b
                      (copy-column-row b-cols b-builders dfb-row)
                      (copy-null-to-row a-cols a-builders))
                    (for ([dfa-row dfa-rows])
                      ; maps possible multiple rows from b to row in a                      
                      (copy-column-row a-cols a-builders (assert dfa-row index?))
                      (copy-column-row b-cols b-builders dfb-row))))))))

; ***********************************************************

; ***********************************************************

; pass in the matched columns as well for display purposes

; This function consumes two DataFrames to join and an optional
; on argument which contains a Listof column names to join on.
; This function does a left join on dfa to dfb.
; Currently this function only supports joining on one column.
(: data-frame-join-left (DataFrame DataFrame [#:on (Listof Symbol)] -> DataFrame))
(define (data-frame-join-left dfa dfb #:on [cols '()])

  ; This function consumes a DataFrame and LabelProjection and
  ; projects those columns.
  (: data-frame-cols (DataFrame LabelProjection -> Columns))
  (define (data-frame-cols data-frame project)
    (data-frame-explode data-frame #:project project))

  ; This function consumes a Listof Column and returns a Vectorof
  ; Series contained in those columns.
  (: src-series (Columns -> (Vectorof Series)))
  (define (src-series cols)
    (list->vector (map column-series cols)))

  (define: cols-a    : (Setof Label) (list->set (data-frame-names dfa)))
  (define: cols-b    : (Setof Label) (list->set (data-frame-names dfb)))
  ; Get the common cols between fa and fb
  (define: join-cols : (Setof Label) (if (null? cols)
					 (set-intersect cols-a cols-b)
					 (set-intersect (list->set cols)
							(set-intersect cols-a cols-b))))

  ;(when (null? join-cols)
    ;(error "No common columns between data-frames to join on."))

  ; The column of fb that are not in the join set.
  (define: non-key-dfb : (Setof Label) (set-subtract cols-b join-cols))

  ; get all dfa-cols regardless of join intersection
  (define: dfa-cols : Columns (data-frame-cols dfa '()))
  ; only get dfb-cols not in join intersection
  (define: dfb-cols : Columns (data-frame-cols dfb non-key-dfb))
  ; only get dfb-cols which match for display purposes
  (define: dfb-cols-match : Columns (data-frame-cols dfb (set-intersect cols-a cols-b)))

  ; Create index on fb dataframe on join-cols.
  (define: dfb-index : JoinHash
    (let ((cols (key-cols-sort-lexical (data-frame-cols dfb join-cols))))
      (index (key-cols-series cols))))

  (define: dfa-keyfn : (Index -> Key)
    (key-fn (key-cols-series (key-cols-sort-lexical (data-frame-cols dfa join-cols)))))
  
  ; Get series builders of default length 10 for all columns in fa.
  (define: dest-builders-a : (Vectorof SeriesBuilder)
    (list->vector (dest-mapping-series-builders (data-frame-description dfa) 10)))

  ; Get series builders of default length 10 for only non-key-fb columns in fb.
  (define: dest-builders-b : (Vectorof SeriesBuilder)
    (list->vector
     (dest-mapping-series-builders (data-frame-description dfb #:project non-key-dfb) 10)))
  
  (do-join-build-left/right (src-series dfa-cols) (src-series dfb-cols) (src-series dfb-cols-match)
		 dest-builders-a dest-builders-b
		 dfa-keyfn dfb-index)

  (define: new-a-series : Columns
    (for/list ([builder (in-vector dest-builders-a)]
	       [col     (in-list dfa-cols)])
	      (cons (join-column-name col cols-a "dfa-")
		    (series-complete builder))))

  (define: new-b-series : Columns
    (for/list ([builder (in-vector dest-builders-b)]
	       [col     (in-list dfb-cols)])
	      (cons (join-column-name col cols-b "dfb-")
		    (series-complete builder))))

  (new-data-frame (append new-a-series new-b-series)))

; ***********************************************************

; ***********************************************************

;; right outer join, just reverse fa and fb operations

; This function consumes two DataFrames to join and an optional
; on argument which contains a Listof column names to join on.
; Currently this function only supports joining on one column.
(: data-frame-join-right (DataFrame DataFrame [#:on (Listof Symbol)] -> DataFrame))
(define (data-frame-join-right dfa dfb #:on [cols '()])

  ; This function consumes a DataFrame and LabelProjection and
  ; projects those columns.
  (: data-frame-cols (DataFrame LabelProjection -> Columns))
  (define (data-frame-cols data-frame project)
    (data-frame-explode data-frame #:project project))

  ; This function consumes a Listof Column and returns a Vectorof
  ; Series contained in those columns.
  (: src-series (Columns -> (Vectorof Series)))
  (define (src-series cols)
    (list->vector (map column-series cols)))

  (define: cols-a    : (Setof Label) (list->set (data-frame-names dfa)))
  (define: cols-b    : (Setof Label) (list->set (data-frame-names dfb)))
  ; Get the common cols between fa and fb
  (define: join-cols : (Setof Label) (if (null? cols)
					 (set-intersect cols-b cols-a)
					 (set-intersect (list->set cols)
							(set-intersect cols-b cols-a))))

  ;(when (null? join-cols)
  ;(error "No common columns between data-frames to join on."))

  ; The column of fa that are not in the join set.
  (define: non-key-dfa : (Setof Label) (set-subtract cols-a join-cols))

  ; get all fb-cols regardless of join intersection
  (define: dfb-cols : Columns (data-frame-cols dfb '()))
  ; only get fa-cols not in join intersection
  (define: dfa-cols : Columns (data-frame-cols dfa non-key-dfa))

  ; only get dfb-cols which match for display purposes
  (define: dfa-cols-match : Columns (data-frame-cols dfa (set-intersect cols-a cols-b)))

  ; Create index on dfa dataframe on join-cols.
  (define: dfa-index : JoinHash
    (let ((cols (key-cols-sort-lexical (data-frame-cols dfa join-cols))))
      (index (key-cols-series cols))))

  (define: dfb-keyfn : (Index -> Key)
    (key-fn (key-cols-series (key-cols-sort-lexical (data-frame-cols dfb join-cols)))))

  ; Get series builders of default length 10 for all columns in fb.
  (define: dest-builders-b : (Vectorof SeriesBuilder)
    (list->vector (dest-mapping-series-builders (data-frame-description dfb) 10)))

  ; Get series builders of default length 10 for only non-key-fb columns in fa.
  (define: dest-builders-a : (Vectorof SeriesBuilder)
    (list->vector
     (dest-mapping-series-builders (data-frame-description dfa #:project non-key-dfa) 10)))

  (do-join-build-left/right (src-series dfb-cols) (src-series dfa-cols) (src-series dfa-cols-match)
		 dest-builders-b dest-builders-a
		 dfb-keyfn dfa-index)

  (define: new-a-series : Columns
    (for/list ([builder (in-vector dest-builders-a)]
	       [col     (in-list dfa-cols)])
	      (cons (join-column-name col cols-a "dfa-")
		    (series-complete builder))))

  (define: new-b-series : Columns
    (for/list ([builder (in-vector dest-builders-b)]
	       [col     (in-list dfb-cols)])
	      (cons (join-column-name col cols-b "dfb-")
		    (series-complete builder))))

  (new-data-frame (append new-a-series new-b-series)))

; ***********************************************************

; ***********************************************************

; This function consumes two DataFrames to join and an optional
; on argument which contains a Listof column names to join on.
; This function does a left join on dfa to dfb.
; Currently this function only supports joining on one column.
(: data-frame-join-inner (DataFrame DataFrame [#:on (Listof Symbol)] -> DataFrame))
(define (data-frame-join-inner dfa dfb #:on [cols '()])

  ; This function consumes a DataFrame and LabelProjection and
  ; projects those columns.
  (: data-frame-cols (DataFrame LabelProjection -> Columns))
  (define (data-frame-cols data-frame project)
    (data-frame-explode data-frame #:project project))

  ; This function consumes a Listof Column and returns a Vectorof
  ; Series contained in those columns.
  (: src-series (Columns -> (Vectorof Series)))
  (define (src-series cols)
    (list->vector (map column-series cols)))

  (define: cols-a    : (Setof Label) (list->set (data-frame-names dfa)))
  (define: cols-b    : (Setof Label) (list->set (data-frame-names dfb)))
  ; Get the common cols between fa and fb
  (define: join-cols : (Setof Label) (if (null? cols)
                                         ;(let ((cols-a-b-intersection (set-intersect cols-a cols-b)))
                                          ; (if (or (= (set-count cols-a-b-intersection) (set-count cols-b)) (= (set-count cols-a-b-intersection) (set-count cols-a)))
                                           ;    (set)
                                            ;   cols-a-b-intersection))
                                         (set-intersect cols-b cols-a)
					 (set-intersect (list->set cols)
							(set-intersect cols-a cols-b))))

  (displayln "Join Cols")

  (displayln join-cols)

  (when (null? join-cols)
	(error "No common columns between data-frames to join on."))

  ;(when (or (= (set-count join-cols) (set-count cols-b)) (= (set-count join-cols) (set-count cols-b)))
   ; (set-clear! join-cols))

  ; The column of fb that are not in the join set.
  (define: non-key-dfb : (Setof Label) (set-subtract cols-b join-cols))

  ; get all dfa-cols regardless of join intersection
  (define: dfa-cols : Columns (data-frame-cols dfa '()))
  ; only get dfb-cols not in join intersection
  (define: dfb-cols : Columns (data-frame-cols dfb '()))

  ; Create index on fb dataframe on join-cols.
  (define: dfb-index : JoinHash
    (let ((cols (key-cols-sort-lexical (data-frame-cols dfb join-cols))))
      (index (key-cols-series cols))))

  (define: dfa-keyfn : (Index -> Key)
    (key-fn (key-cols-series (key-cols-sort-lexical (data-frame-cols dfa join-cols)))))

  ; Get series builders of default length 10 for all columns in fa.
  (define: dest-builders-a : (Vectorof SeriesBuilder)
    (list->vector (dest-mapping-series-builders (data-frame-description dfa) 10)))

  ; Get series builders of default length 10 for only non-key-fb columns in fb.
  (define: dest-builders-b : (Vectorof SeriesBuilder)
    (list->vector
     (dest-mapping-series-builders (data-frame-description dfb) 10)))

  (do-join-build-inner (src-series dfa-cols) (src-series dfb-cols)
		 dest-builders-a dest-builders-b
		 dfa-keyfn dfb-index)

  (define: new-a-series : Columns
    (for/list ([builder (in-vector dest-builders-a)]
	       [col     (in-list dfa-cols)])
	      (cons (join-column-name col cols-a "dfa-")
		    (series-complete builder))))

  (define: new-b-series : Columns
    (for/list ([builder (in-vector dest-builders-b)]
	       [col     (in-list dfb-cols)])
	      (cons (join-column-name col cols-b "dfb-")
		    (series-complete builder))))

  (new-data-frame (append new-a-series new-b-series)))

; ***********************************************************

; ***********************************************************

; This function consumes two DataFrames to join and an optional
; on argument which contains a Listof column names to join on.
; This function does a left join on dfa to dfb.
; Currently this function only supports joining on one column.
(: data-frame-join-outer (DataFrame DataFrame [#:on (Listof Symbol)] -> DataFrame))
(define (data-frame-join-outer dfa dfb #:on [cols '()])

  ; This function consumes a DataFrame and LabelProjection and
  ; projects those columns.
  (: data-frame-cols (DataFrame LabelProjection -> Columns))
  (define (data-frame-cols data-frame project)
    (data-frame-explode data-frame #:project project))

  ; This function consumes a Listof Column and returns a Vectorof
  ; Series contained in those columns.
  (: src-series (Columns -> (Vectorof Series)))
  (define (src-series cols)
    (list->vector (map column-series cols)))

  (define: cols-a    : (Setof Label) (list->set (data-frame-names dfa)))
  (define: cols-b    : (Setof Label) (list->set (data-frame-names dfb)))
  ; Get the common cols between fa and fb
  (define: join-cols : (Setof Label) (if (null? cols)
					 (set-intersect cols-a cols-b)
					 (set-intersect (list->set cols)
							(set-intersect cols-a cols-b))))

  ;(when (null? join-cols)
  ;(error "No common columns between data-frames to join on."))

  ; The column of fb that are not in the join set.
  (define: non-key-dfb : (Setof Label) (set-subtract cols-b join-cols))

  ; get all dfa-cols regardless of join intersection
  (define: dfa-cols : Columns (data-frame-cols dfa '()))
  ; only get dfb-cols not in join intersection
  (define: dfb-cols : Columns (data-frame-cols dfb '()))

  ; Create index on fb dataframe on join-cols.
  (define: dfa-index : JoinHash
    (let ((cols (key-cols-sort-lexical (data-frame-cols dfa join-cols))))
      (index (key-cols-series cols))))
  
  ; Create index on fb dataframe on join-cols.
  (define: dfb-index : JoinHash
    (let ((cols (key-cols-sort-lexical (data-frame-cols dfb join-cols))))
      (index (key-cols-series cols))))

  (define: dfa-keyfn : (Index -> Key)
    (key-fn (key-cols-series (key-cols-sort-lexical (data-frame-cols dfa join-cols)))))

  (define: dfb-keyfn : (Index -> Key)
    (key-fn (key-cols-series (key-cols-sort-lexical (data-frame-cols dfb join-cols)))))

  ; Get series builders of default length 10 for all columns in fa.
  (define: dest-builders-a : (Vectorof SeriesBuilder)
    (list->vector (dest-mapping-series-builders (data-frame-description dfa) 10)))

  ; Get series builders of default length 10 for only non-key-fb columns in fb.
  (define: dest-builders-b : (Vectorof SeriesBuilder)
    (list->vector
     (dest-mapping-series-builders (data-frame-description dfb) 10)))

  (do-join-build-outer (src-series dfa-cols) (src-series dfb-cols)
		 dest-builders-a dest-builders-b
		 dfa-keyfn dfb-keyfn dfa-index dfb-index)

  (define: new-a-series : Columns
    (for/list ([builder (in-vector dest-builders-a)]
	       [col     (in-list dfa-cols)])
	      (cons (join-column-name col cols-a "dfa-")
		    (series-complete builder))))

  (define: new-b-series : Columns
    (for/list ([builder (in-vector dest-builders-b)]
	       [col     (in-list dfb-cols)])
	      (cons (join-column-name col cols-b "dfb-")
		    (series-complete builder))))

  (new-data-frame (append new-a-series new-b-series)))

; ***********************************************************

; ***********************************************************

; This function is self-explanatory, it consumes no arguments
; and creates a hash map which will represent a JoinHash.
(: make-group-hash (-> GroupHash))
(define (make-group-hash)
  (make-hash))

;Used to determine the groups for the groupby. If by is a function, it’s called on each value of the object’s index. If a dict or Series is passed, the Series or dict VALUES will be used to determine the groups (the Series’ values are first aligned; see .align() method). If an ndarray is passed, the values are used as-is determine the groups. A label or list of labels may be passed to group by the columns in self. Notice that a tuple is interpreted a (single) key.
(: data-frame-groupby (DataFrame (Listof Label) -> GroupHash))
(define (data-frame-groupby data-frame by)
  (define: group-index : GroupHash (make-group-hash))
  (define: col-groups : (Listof IndexableSeries) (key-cols-series (data-frame-explode data-frame #:project by)))
  (define: col-data : (Listof IndexableSeries) (key-cols-series (data-frame-explode data-frame #:project (set-subtract (list->set (data-frame-names data-frame)) (list->set by)))))

  ; Get length of one of the IndexableSeries
  (define len (series-length (car col-groups)))
  (define: group-key : (Index -> String) (key-fn col-groups))

  (let loop ([i 0])
    (if (unsafe-fx>= i len)
	group-index
	(let: ((i : Index (assert i index?)))
	      (let ((key (group-key i)))
		(hash-update! group-index key
			      (λ: ((idx : (Listof GenericType)))
				  (append (map (lambda ([series : IndexableSeries]) (series-iref series i)) col-data) idx))
			      (λ () (list))))
	      (loop (add1 i))))))

; ***********************************************************

; ***********************************************************
;; DataFrame agg ops

; Applies the aggregate function specificed by function-name to the values in
; the column-name column. Currently supports 3: sum, avg, count.
(: apply-agg-data-frame (Symbol GroupHash -> Series))
(define (apply-agg-data-frame function-name group-hash)
  (define len (hash-count group-hash))

  (: agg-value-hash AggValueHash)
  (define agg-value-hash (make-hash))

  (hash-for-each group-hash
                 (lambda ([key : String] [val : (Listof GenericType)])
                   
                   (let ((key (assert key string?))
                         (val (assert (flatten val) ListofReal?)))
                     (hash-set! agg-value-hash key
                                (cond 
                                  [(eq? function-name 'sum) (apply + val)]
                                  [(eq? function-name 'mean) (mean val)]
                                  ;[(eq? function-name 'median) (median (vector->list (ISeries-data series)))]
                                  ;[(eq? function-name 'mode) (mode (vector->list (ISeries-data series)))]
                                  [(eq? function-name 'count) (length val)]
                                  [(eq? function-name 'min) (argmin (lambda ([x : Real]) x) val)]
                                  [(eq? function-name 'max) (argmax (lambda ([x : Real]) x) val)]
                                  [else (error 'apply-agg-data-frame "Unknown aggregate function.")])))))

  (agg-value-hash-to-series agg-value-hash))

(: make-agg-value-hash-sindex ((Listof (Pair String GenericType)) -> SIndex))
(define (make-agg-value-hash-sindex sorted-agg-value-hash)
  (let ((index : SIndex (make-hash '()))
          (len (length sorted-agg-value-hash)))
    
      (begin
        (let loop ([i 0])
          (if (>= i len)
              index
              (let: ((i : Index (assert i index?)))
                (let ((key (car (list-ref sorted-agg-value-hash i))))
                  (hash-update! index (string->symbol key)
                                (λ: ((idx : (Listof Index)))
                                  (append idx (list i)))
                                (λ () (list))))
                (loop (add1 i)))))
        index)))

(: agg-value-hash-to-series (AggValueHash -> Series))
(define (agg-value-hash-to-series agg-value-hash)
  (let ((sorted-agg-value-hash
         ((inst sort (Pair String GenericType) (Pair String GenericType))
         (hash->list agg-value-hash)
         (λ: ((kv1 : (Pair String GenericType))
              (kv2 : (Pair String GenericType)))
           (string<? (car kv1) (car kv2))))))

    (let ((index : SIndex (make-agg-value-hash-sindex sorted-agg-value-hash)))
      (new-GenSeries (for/vector: : (Vectorof GenericType) ([p sorted-agg-value-hash])
                       (cdr p)) index))))

; **********************************************************

; ***********************************************************

(: build-multi-index-from-cols ((U (Listof IndexableSeries) Columns) -> SIndex))
(define (build-multi-index-from-cols cols)

  (let ((cols : (Listof IndexableSeries)
              (if (Columns? cols)
                  (key-cols-series cols)
                  cols)))

    ; Get length of one of the IndexableSeries
    (define len (series-length (car cols)))
    (define: series-key : (Index -> String) (key-fn cols))

    (let ((index : SIndex (make-hash '())))
      (let loop ([i 0])
        (if (>= i len)
            index
            (let: ((i : Index (assert i index?)))
              (let ((key (series-key i)))
                (hash-update! index (string->symbol key)
                              (λ: ((idx : (Listof Index)))
                                (append idx (list i)))
                              (λ () (list))))
              (loop (add1 i))))))))

; **********************************************************