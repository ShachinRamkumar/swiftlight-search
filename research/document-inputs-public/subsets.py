"""The public subsets, pinned to dataset commits. Text sources are named per subset (see REPORT.md, Deviations)."""

SUBSETS = {
    # name: (HF dataset, revision, layout, text source, page cap)
    'energy': ('vidore/syntheticDocQA_energy_test', 'a2f2f358463b03b84506849460ab5094a358526c', 'v1',
               ('tesseract-dataset', 'vidore/syntheticDocQA_energy_test_tesseract',
                '2ae81641b592eb99387af754f4db203f01815b42'), 500),
    'biomedical_lectures': ('vidore/biomedical_lectures_eng_v2', 'e82eb2f3e9f701688e6f3ba41fffad68c5b3b5fa', 'v2',
                            ('tesseract-local',), 500),
    'shift': ('vidore/shiftproject_test', '6e6223b3839a3f4e62d676e70a1b715ee520cc66', 'v1',
              ('tesseract-dataset', 'vidore/shiftproject_test_tesseract',
               '494949aaaf202d450ece1ae70a7e87b703f550a5'), 500),
    'ai': ('vidore/syntheticDocQA_artificial_intelligence_test', '5694fec64c57f7380f918435f9234b96d817b82a', 'v1',
           ('tesseract-dataset', 'vidore/syntheticDocQA_artificial_intelligence_test_tesseract',
            '9d6880f4f97a5e4726b18b6ab600bb136bda3cd0'), 500),
    'arxivqa': ('vidore/arxivqa_test_subsampled', 'b8a106812c8682bab08935cf5d1b4566c82562de', 'v1',
                ('tesseract-local',), 500),
    'infovqa': ('vidore/infovqa_test_subsampled', 'f793e830aaeae1ceb8a2df626fc555b3fd04d3db', 'v1',
                ('textract-dataset',), 500),
    'esg_reports': ('vidore/esg_reports_eng_v2', '9c88db1f8b7b5e7a629ed3cbaf1056ee170db9bb', 'v2',
                    ('tesseract-local',), 500),
}
ORDER = list(SUBSETS)
SEED = 20261027
