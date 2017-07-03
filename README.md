# elastic-rotation
Elasticsearch Daily Index Rotation Tool

For a given cluster and a snapshot repository, make snapshots of daily indices 
 (named with "<prefix>YYYY.DD.MM" pattern) and deletes the old ones.

Must be called with ALL the following parameters:

    --url           elasticsearch url, eg. https://<host>:<port>
    --repository    snapshot repository
    --index-prefix  index pattern to be rotated
    --index-age     days to keep indices - the older ones will be deleted
