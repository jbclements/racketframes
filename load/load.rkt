#lang typed/racket

(provide:
 [determine-schema (FilePath Integer -> Schema)]
 [load-csv-file (FilePath [#:schema (Option Schema)] -> DataFrame)]
 [load-delimited-file (FilePath String [#:schema (Option Schema)] -> DataFrame)])

(require
 racket/match
 (only-in grip/data/list
	  zip)
 (only-in grip/system/filepath
	  FilePath FilePath->string)
 (only-in "schema.rkt"
	  generate-anon-series-names
	  Schema ColumnInfo SeriesTypes Schema-has-headers
	  Schema-SeriesTypes Schema-headers)
 (only-in "../data-frame/series-builder.rkt"
	  SeriesBuilder)
 (only-in "../data-frame/integer-series-builder.rkt"
	  new-ISeriesBuilder
	  ISeriesBuilder
	  ISeriesBuilder?
	  complete-ISeriesBuilder)
 (only-in "../data-frame/boolean-series-builder.rkt"
	  new-BSeriesBuilder
	  BSeriesBuilder
	  BSeriesBuilder?
	  complete-BSeriesBuilder)
 (only-in "../data-frame/numeric-series-builder.rkt"
	  new-NSeriesBuilder
	  NSeriesBuilder
	  NSeriesBuilder?
	  complete-NSeriesBuilder)
 (only-in "../data-frame/categorical-series-builder.rkt"
	  new-CSeriesBuilder
	  CSeriesBuilder
	  CSeriesBuilder?
	  complete-CSeriesBuilder
	  append-CSeriesBuilder)
 (only-in "../data-frame/series-description.rkt"
	  Series)
 (only-in "../data-frame/data-frame.rkt"
	  DataFrame
	  new-data-frame
          data-frame-explode)
 (only-in "../data-frame/data-frame-print.rkt"
          frame-write-tab)
 "data-frame-builder.rkt"
 (only-in "delimited-common.rkt"
	  sample-formatted-file
	  check-data-file-exists)
 (only-in "schema.rkt"
	  Schema)
 (only-in "sample.rkt"
	  determine-schema-from-sample)
 (only-in "csv-delimited.rkt"
	  read-csv-file)
 (only-in "delimited.rkt"
	  read-delimited-file))


(: new-DataFrameBuilder-from-Schema (Schema -> DataFrameBuilder))
(define (new-DataFrameBuilder-from-Schema schema)

  (: determine-SeriesBuilder (SeriesTypes -> SeriesBuilder))
  (define (determine-SeriesBuilder stypes)
    (match stypes
      ['CATEGORICAL (new-CSeriesBuilder)]
      ['INTEGER     (new-ISeriesBuilder)]
      ['NUMERIC     (new-NSeriesBuilder)]
      ['BOOLEAN     (new-BSeriesBuilder)]))

  (DataFrameBuilder ((inst map SeriesBuilder SeriesTypes)
		 determine-SeriesBuilder
		 (Schema-SeriesTypes schema))))

(: complete-SeriesBuilders (DataFrameBuilder -> (Listof Series)))
(define (complete-SeriesBuilders frame-builder)
  (map (λ: ((builder : SeriesBuilder))
	   (cond
	    [(CSeriesBuilder? builder)
	     (complete-CSeriesBuilder builder)]
	    [(ISeriesBuilder? builder)
	     (complete-ISeriesBuilder builder)]
            [(BSeriesBuilder? builder)
	     (complete-BSeriesBuilder builder)]
	    [(NSeriesBuilder? builder)
	     (complete-NSeriesBuilder builder)]
	    [else (error "Inconsistent DataFrameBuilder")]))
       (DataFrameBuilder-builders frame-builder)))

(: anon-headers (Integer -> (Listof Symbol)))
(define (anon-headers cnt)
  (map string->symbol (generate-anon-series-names cnt)))

(: make-data-frame (Schema DataFrameBuilder -> DataFrame))
(define (make-data-frame schema builder)
  (let ((cols (complete-SeriesBuilders builder)))
    (let ((headers (if (Schema-has-headers schema)
		       (Schema-headers schema)
		       (anon-headers (length cols)))))
      (new-data-frame ((inst zip Symbol Series) headers cols)))))

(: schema-if-needed ((Option Schema) FilePath -> Schema))
(define (schema-if-needed schema fpath)
  (define SAMPLE-SIZE 20)
  (if schema schema (determine-schema fpath SAMPLE-SIZE)))

; delimiter must be specified by user if no schema provided
(: load-csv-file (FilePath [#:schema (Option Schema)] [#:delim (Option Fixnum)] -> DataFrame))
(define (load-csv-file fpath #:schema [schema #f] #:delim [delim #f])
  (let ((schema (schema-if-needed schema fpath)))
    (make-data-frame schema (read-csv-file fpath
				      (Schema-has-headers schema)
				      (new-DataFrameBuilder-from-Schema schema)))))

(: load-delimited-file (FilePath String [#:schema (Option Schema)] -> DataFrame))
(define (load-delimited-file fpath delim #:schema [schema #f])
  (let ((schema (schema-if-needed schema fpath)))
    (make-data-frame schema (read-delimited-file fpath
                                            (Schema-has-headers schema)
                                            (new-DataFrameBuilder-from-Schema schema)
                                            delim))))
(: determine-schema (FilePath Integer -> Schema))
(define (determine-schema fpath cnt)
  (check-data-file-exists fpath)
  (determine-schema-from-sample (sample-formatted-file fpath cnt) ","))

; test cases

;(data-frame-explode fruits-data-frame)

;(define fruits-schema (Schema #t (list (ColumnInfo 'name 'CATEGORICAL) (ColumnInfo 'quantity 'CATEGORICAL) (ColumnInfo 'price 'CATEGORICAL))))

; read csv
;(define fruits-data-frame-csv (load-csv-file (FilePath "../data-frame/fruits.csv") #:schema fruits-schema))

;(frame-write-tab fruits-data-frame-csv (current-output-port))

; no schema
;(define fruits-data-frame-csv-no-schema (load-csv-file (FilePath "../data-frame/fruits.csv") #:schema #f))

;(frame-write-tab fruits-data-frame-csv-no-schema (current-output-port))

; read delimited
;(define fruits-data-frame-delimited (load-delimited-file (FilePath "../data-frame/fruits.csv") "," #:schema fruits-schema))

;(frame-write-tab fruits-data-frame-delimited (current-output-port))

; no schema
;(define fruits-data-frame-delimited-no-schema (load-delimited-file (FilePath "../data-frame/fruits.csv") "," #:schema #f))

;(frame-write-tab fruits-data-frame-delimited-no-schema (current-output-port))