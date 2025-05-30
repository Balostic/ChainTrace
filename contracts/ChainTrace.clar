;; ChainTrace - Supply Chain Transparency and Verification Network
(define-fungible-token verification-token)

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-access-denied (err u501))
(define-constant err-insufficient-tokens (err u301))
(define-constant err-shipment-not-found (err u302))
(define-constant err-already-verified (err u303))
(define-constant err-verification-expired (err u304))
(define-constant err-verification-pending (err u305))
(define-constant err-invalid-product-name (err u306))
(define-constant err-invalid-origin-info (err u307))
(define-constant err-invalid-tracking-code (err u308))
(define-constant err-invalid-token-amount (err u309))

;; Storage
(define-map shipment-records uint {
  supplier: principal,
  product-name: (string-utf8 64),
  origin-details: (string-utf8 256),
  tracking-reference: (string-utf8 128),
  authenticity-confirmations: uint,
  fraud-reports: uint,
  verification-state: (string-utf8 16),
  expiry-timestamp: uint
})

(define-map verifications {shipment-id: uint, verifier: principal} bool)
(define-map supplier-tokens principal uint)
(define-data-var shipment-id-counter uint u0)
(define-data-var min-verification-stake uint u25000000) ;; 25 tokens
(define-data-var verification-window uint u432) ;; ~3 days in blocks

;; Initialize verification tokens for supply chain
(define-public (issue-verification-tokens (token-quantity uint))
  (begin
    ;; Validate inputs
    (asserts! (> token-quantity u0) err-invalid-token-amount)
    
    ;; Check authorization
    (asserts! (is-eq tx-sender contract-owner) err-access-denied)
    
    ;; Mint tokens
    (try! (ft-mint? verification-token token-quantity tx-sender))
    
    ;; Update supplier tokens
    (ok (map-set supplier-tokens tx-sender token-quantity))
  )
)

;; Register new shipment for verification
(define-public (register-shipment (product-name (string-utf8 64)) (origin-details (string-utf8 256)) (tracking-reference (string-utf8 128)))
  (let
    ((supplier tx-sender)
     (shipment-id (var-get shipment-id-counter))
     (token-balance (default-to u0 (map-get? supplier-tokens supplier))))
    
    ;; Validate inputs
    (asserts! (> (len product-name) u0) err-invalid-product-name)
    (asserts! (> (len origin-details) u0) err-invalid-origin-info)
    (asserts! (> (len tracking-reference) u0) err-invalid-tracking-code)
    
    ;; Check if supplier has enough tokens
    (asserts! (>= token-balance (var-get min-verification-stake)) err-insufficient-tokens)
    
    ;; Store the shipment record
    (map-set shipment-records shipment-id {
      supplier: supplier,
      product-name: product-name,
      origin-details: origin-details,
      tracking-reference: tracking-reference,
      authenticity-confirmations: u0,
      fraud-reports: u0,
      verification-state: u"pending",
      expiry-timestamp: (+ burn-block-height (var-get verification-window))
    })
    
    ;; Increment the shipment ID counter
    (var-set shipment-id-counter (+ shipment-id u1))
    
    (ok shipment-id)))

;; Verify shipment authenticity
(define-public (verify-shipment (shipment-id uint) (is-authentic bool))
  (let
    ((shipment (unwrap! (map-get? shipment-records shipment-id) err-shipment-not-found))
     (verifier tx-sender)
     (token-balance (default-to u0 (map-get? supplier-tokens verifier)))
     (verification-key {shipment-id: shipment-id, verifier: verifier}))
    
    ;; Check if verification period is still active
    (asserts! (< burn-block-height (get expiry-timestamp shipment)) err-verification-expired)
    
    ;; Check if verifier has already verified
    (asserts! (is-none (map-get? verifications verification-key)) err-already-verified)
    
    ;; Record the verification
    (map-set verifications verification-key true)
    
    ;; Update verification counts
    (if is-authentic
      (ok (map-set shipment-records shipment-id (merge shipment {authenticity-confirmations: (+ (get authenticity-confirmations shipment) token-balance)})))
      (ok (map-set shipment-records shipment-id (merge shipment {fraud-reports: (+ (get fraud-reports shipment) token-balance)})))
    )
  )
)

;; Finalize shipment verification status
(define-public (finalize-verification (shipment-id uint))
  (let
    ((shipment (unwrap! (map-get? shipment-records shipment-id) err-shipment-not-found)))
    
    ;; Check if verification period has ended
    (asserts! (>= burn-block-height (get expiry-timestamp shipment)) err-verification-pending)
    
    ;; Update verification status
    (ok (map-set shipment-records shipment-id 
      (merge shipment 
        {verification-state: (if (> (get authenticity-confirmations shipment) (get fraud-reports shipment)) u"verified" u"flagged")})))
  )
)

;; Get shipment record details
(define-read-only (get-shipment-record (shipment-id uint))
  (map-get? shipment-records shipment-id))

;; Get supplier token balance
(define-read-only (get-supplier-tokens (supplier principal))
  (default-to u0 (map-get? supplier-tokens supplier)))

;; Transfer verification tokens
(define-public (transfer-tokens (token-amount uint) (recipient principal))
  (let
    ((sender tx-sender)
     (sender-balance (default-to u0 (map-get? supplier-tokens sender)))
     (recipient-balance (default-to u0 (map-get? supplier-tokens recipient))))
    
    ;; Validate inputs
    (asserts! (> token-amount u0) err-invalid-token-amount)
    (asserts! (not (is-eq recipient 'SP000000000000000000002Q6VF78)) err-access-denied)
    
    ;; Check if sender has enough tokens
    (asserts! (>= sender-balance token-amount) err-insufficient-tokens)
    
    ;; Update balances
    (map-set supplier-tokens sender (- sender-balance token-amount))
    (ok (map-set supplier-tokens recipient (+ recipient-balance token-amount)))
  )
)