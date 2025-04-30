;; nodelink-core
;; Manages node registration, file indexing, and access permissions for the NodeLink P2P network
;; This contract serves as the coordination layer for the NodeLink P2P file sharing network.
;; It handles node registration, reputation tracking, file indexing, and access control.

;; Error codes
(define-constant ERR-NOT-REGISTERED (err u100))
(define-constant ERR-ALREADY-REGISTERED (err u101))
(define-constant ERR-FILE-NOT-FOUND (err u102))
(define-constant ERR-UNAUTHORIZED (err u103))
(define-constant ERR-ALREADY-EXISTS (err u104))
(define-constant ERR-INSUFFICIENT-REPUTATION (err u105))
(define-constant ERR-INVALID-REPUTATION-CHANGE (err u106))
(define-constant ERR-NODE-NOT-FOUND (err u107))
(define-constant ERR-SELF-RATING (err u108))
(define-constant ERR-INVALID-PARAMETER (err u109))

;; Constants
(define-constant MIN-REPUTATION-TO-SHARE u10)
(define-constant DEFAULT-REPUTATION u50)
(define-constant MAX-REPUTATION u100)
(define-constant MIN-REPUTATION u0)
(define-constant MAX-REPUTATION-CHANGE u5)
(define-constant CONTRACT-OWNER tx-sender)

;; Data storage

;; Node registry - tracks registered network nodes and their reputation scores
;; Maps node address to node data (active status and reputation score)
(define-map nodes 
  { node-address: principal }
  { 
    active: bool,
    reputation: uint,
    registration-height: uint
  }
)

;; File metadata storage - indexes files shared on the network
;; Maps file-id to file metadata
(define-map files
  { file-id: (string-ascii 64) }
  {
    name: (string-ascii 100),
    description: (string-utf8 500),
    size: uint,
    content-type: (string-ascii 50),
    hash: (buff 32),
    owner: principal,
    is-public: bool
  }
)

;; Tracks which files are shared by which nodes
;; Maps combination of file-id and node to sharing status
(define-map file-node-mapping
  { 
    file-id: (string-ascii 64),
    node: principal 
  }
  { is-sharing: bool }
)

;; Access permissions for private files
;; Maps combination of file-id and user to permission status
(define-map file-access-permissions
  {
    file-id: (string-ascii 64),
    user: principal
  }
  { has-access: bool }
)

;; Private functions

;; Checks if a principal is a registered active node
(define-private (is-registered-node (node principal))
  (match (map-get? nodes { node-address: node })
    node-data (and (get active node-data) true)
    false
  )
)

;; Gets a node's reputation, returns 0 if not registered
(define-private (get-node-reputation (node principal))
  (default-to u0
    (get reputation
      (default-to { active: false, reputation: u0, registration-height: u0 }
        (map-get? nodes { node-address: node })
      )
    )
  )
)

;; Safely adjusts reputation within bounds
(define-private (adjust-reputation (current-rep uint) (adjustment int))
  (let
    (
      (new-rep-raw (+ current-rep adjustment))
      (bounded-rep (if (< new-rep-raw MIN-REPUTATION)
                      MIN-REPUTATION
                      (if (> new-rep-raw MAX-REPUTATION)
                        MAX-REPUTATION
                        new-rep-raw)))
    )
    bounded-rep
  )
)

;; Checks if a user has access to a file
(define-private (has-file-access (file-id (string-ascii 64)) (user principal))
  (match (map-get? files { file-id: file-id })
    file-data (or
                (get is-public file-data)
                (is-eq (get owner file-data) user)
                (default-to false
                  (get has-access
                    (default-to { has-access: false }
                      (map-get? file-access-permissions { file-id: file-id, user: user })
                    )
                  )
                )
              )
    false
  )
)

;; Read-only functions

;; Check if an address is registered as a node
(define-read-only (is-node-registered (node principal))
  (is-registered-node node)
)

;; Get node information including reputation
(define-read-only (get-node-info (node principal))
  (map-get? nodes { node-address: node })
)

;; Get file metadata
(define-read-only (get-file-info (file-id (string-ascii 64)))
  (map-get? files { file-id: file-id })
)

;; Check if a file is being shared by a specific node
(define-read-only (is-file-shared-by-node (file-id (string-ascii 64)) (node principal))
  (default-to false
    (get is-sharing
      (default-to { is-sharing: false }
        (map-get? file-node-mapping { file-id: file-id, node: node })
      )
    )
  )
)

;; Check if user has access to a file
(define-read-only (check-file-access (file-id (string-ascii 64)) (user principal))
  (has-file-access file-id user)
)

;; Public functions

;; Register as a node in the network
(define-public (register-node)
  (let
    ((sender tx-sender))
    (if (is-registered-node sender)
      ERR-ALREADY-REGISTERED
      (begin
        (map-set nodes
          { node-address: sender }
          {
            active: true,
            reputation: DEFAULT-REPUTATION,
            registration-height: block-height
          }
        )
        (ok true)
      )
    )
  )
)

;; Deactivate a node (can only deactivate yourself)
(define-public (deactivate-node)
  (let
    ((sender tx-sender))
    (match (map-get? nodes { node-address: sender })
      node-data (begin
                  (map-set nodes
                    { node-address: sender }
                    (merge node-data { active: false })
                  )
                  (ok true)
                )
      ERR-NOT-REGISTERED
    )
  )
)

;; Reactivate a previously deactivated node
(define-public (reactivate-node)
  (let
    ((sender tx-sender))
    (match (map-get? nodes { node-address: sender })
      node-data (begin
                  (map-set nodes
                    { node-address: sender }
                    (merge node-data { active: true })
                  )
                  (ok true)
                )
      ERR-NOT-REGISTERED
    )
  )
)

;; Publish a new file to the network
(define-public (publish-file
    (file-id (string-ascii 64))
    (name (string-ascii 100))
    (description (string-utf8 500))
    (size uint)
    (content-type (string-ascii 50))
    (hash (buff 32))
    (is-public bool))
  (let
    ((sender tx-sender))
    
    ;; Check that publisher is a registered node with sufficient reputation
    (asserts! (is-registered-node sender) ERR-NOT-REGISTERED)
    (asserts! (>= (get-node-reputation sender) MIN-REPUTATION-TO-SHARE) ERR-INSUFFICIENT-REPUTATION)
    
    ;; Check that file ID is not already in use
    (asserts! (is-none (map-get? files { file-id: file-id })) ERR-ALREADY-EXISTS)
    
    ;; Store file metadata
    (map-set files
      { file-id: file-id }
      {
        name: name,
        description: description,
        size: size,
        content-type: content-type,
        hash: hash,
        owner: sender,
        is-public: is-public
      }
    )
    
    ;; Register that this node is sharing the file
    (map-set file-node-mapping
      { file-id: file-id, node: sender }
      { is-sharing: true }
    )
    
    (ok true)
  )
)

;; Update existing file metadata (owner only)
(define-public (update-file-metadata
    (file-id (string-ascii 64))
    (name (string-ascii 100))
    (description (string-utf8 500))
    (content-type (string-ascii 50))
    (is-public bool))
  (let
    ((sender tx-sender))
    
    ;; Get current file data
    (match (map-get? files { file-id: file-id })
      file-data (begin
                  ;; Check that sender is the file owner
                  (asserts! (is-eq (get owner file-data) sender) ERR-UNAUTHORIZED)
                  
                  ;; Update file metadata while preserving other fields
                  (map-set files
                    { file-id: file-id }
                    (merge file-data {
                      name: name,
                      description: description,
                      content-type: content-type,
                      is-public: is-public
                    })
                  )
                  (ok true)
                )
      ERR-FILE-NOT-FOUND
    )
  )
)

;; Start sharing an existing file from your node
(define-public (share-file (file-id (string-ascii 64)))
  (let
    ((sender tx-sender))
    
    ;; Check that sharer is a registered node
    (asserts! (is-registered-node sender) ERR-NOT-REGISTERED)
    
    ;; Check that file exists
    (asserts! (is-some (map-get? files { file-id: file-id })) ERR-FILE-NOT-FOUND)
    
    ;; Check that user has access to the file
    (asserts! (has-file-access file-id sender) ERR-UNAUTHORIZED)
    
    ;; Register that this node is sharing the file
    (map-set file-node-mapping
      { file-id: file-id, node: sender }
      { is-sharing: true }
    )
    
    (ok true)
  )
)

;; Stop sharing a file from your node
(define-public (stop-sharing-file (file-id (string-ascii 64)))
  (let
    ((sender tx-sender))
    
    ;; Check that file exists
    (asserts! (is-some (map-get? files { file-id: file-id })) ERR-FILE-NOT-FOUND)
    
    ;; Remove sharing status
    (map-set file-node-mapping
      { file-id: file-id, node: sender }
      { is-sharing: false }
    )
    
    (ok true)
  )
)

;; Grant access to a private file for a specific user
(define-public (grant-file-access (file-id (string-ascii 64)) (user principal))
  (let
    ((sender tx-sender))
    
    ;; Get current file data
    (match (map-get? files { file-id: file-id })
      file-data (begin
                  ;; Check that sender is the file owner
                  (asserts! (is-eq (get owner file-data) sender) ERR-UNAUTHORIZED)
                  
                  ;; Grant access to the specified user
                  (map-set file-access-permissions
                    { file-id: file-id, user: user }
                    { has-access: true }
                  )
                  (ok true)
                )
      ERR-FILE-NOT-FOUND
    )
  )
)

;; Revoke access to a private file for a specific user
(define-public (revoke-file-access (file-id (string-ascii 64)) (user principal))
  (let
    ((sender tx-sender))
    
    ;; Get current file data
    (match (map-get? files { file-id: file-id })
      file-data (begin
                  ;; Check that sender is the file owner
                  (asserts! (is-eq (get owner file-data) sender) ERR-UNAUTHORIZED)
                  
                  ;; Revoke access
                  (map-set file-access-permissions
                    { file-id: file-id, user: user }
                    { has-access: false }
                  )
                  (ok true)
                )
      ERR-FILE-NOT-FOUND
    )
  )
)

;; Report successful transfer (increases reputation of target node)
(define-public (report-successful-transfer (node principal) (reputation-increase uint))
  (let
    ((sender tx-sender))
    
    ;; Reporter must be a registered node
    (asserts! (is-registered-node sender) ERR-NOT-REGISTERED)
    
    ;; Cannot rate yourself
    (asserts! (not (is-eq sender node)) ERR-SELF-RATING)
    
    ;; Target must be a registered node
    (asserts! (is-registered-node node) ERR-NODE-NOT-FOUND)
    
    ;; Check reputation increase is within allowed bounds
    (asserts! (<= reputation-increase MAX-REPUTATION-CHANGE) ERR-INVALID-REPUTATION-CHANGE)
    
    ;; Get current reputation
    (match (map-get? nodes { node-address: node })
      node-data (begin
                  ;; Update reputation
                  (map-set nodes
                    { node-address: node }
                    (merge node-data {
                      reputation: (adjust-reputation (get reputation node-data) reputation-increase)
                    })
                  )
                  (ok true)
                )
      ERR-NODE-NOT-FOUND
    )
  )
)

;; Report node violation (decreases reputation)
(define-public (report-violation (node principal) (reputation-decrease uint))
  (let
    ((sender tx-sender))
    
    ;; Reporter must be a registered node
    (asserts! (is-registered-node sender) ERR-NOT-REGISTERED)
    
    ;; Cannot rate yourself
    (asserts! (not (is-eq sender node)) ERR-SELF-RATING)
    
    ;; Target must be a registered node
    (asserts! (is-registered-node node) ERR-NODE-NOT-FOUND)
    
    ;; Check reputation decrease is within allowed bounds
    (asserts! (<= reputation-decrease MAX-REPUTATION-CHANGE) ERR-INVALID-REPUTATION-CHANGE)
    
    ;; Get current reputation
    (match (map-get? nodes { node-address: node })
      node-data (begin
                  ;; Update reputation (negative adjustment)
                  (map-set nodes
                    { node-address: node }
                    (merge node-data {
                      reputation: (adjust-reputation (get reputation node-data) (* -1 (to-int reputation-decrease)))
                    })
                  )
                  (ok true)
                )
      ERR-NODE-NOT-FOUND
    )
  )
)