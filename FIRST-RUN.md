# First-run readiness

The Core AI query worker prepares and retains q32 before answering short queries. Other query sizes load on demand. Worker preparation overlaps vector loading. Startup uses the installed runtime fingerprint or an external receipt created after full hash verification; a changed file identity invalidates the receipt.

Normal indexing prepares q32 before documents, then loads media partitions when their content is reached. Small documents and recent files in Desktop, Documents, and Downloads run first. Document keywords become searchable while models prepare. Their provisional rows are removed inside the normal content transaction. Only a new normal index receives the `first_run_embedding_model` marker that permits partial semantic coverage. Existing shadow indexes retain their complete/active requirement and generation fences.

Indexing pauses for keystrokes and resumes after 1.5 seconds without typing. Leaving the panel open does not renew that pause. Model preparation, indexing percentage, and semantic file coverage appear in the existing logs. Audio/video indexing remains off by default.

Background preparation failures make a one-shot index service exit unsuccessfully, including an empty-index run. Readiness is published before waiting indexing work is released.
