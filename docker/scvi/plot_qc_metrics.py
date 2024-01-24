import scanpy as sc
import anndata as ad
from .utils.helpers import minify_adata
import argparse
import pandas as pc

# Create the parser
parser = argparse.ArgumentParser(description='Call doublets')

# Add arguments
parser.add_argument('--working-dir', dest='working_dir', type=str, 
                    help='Working directory', default='/data/CARD_singlecell/harmony-rna/')
parser.add_argument('--script-dir', dest='script_dir', type=str, 
                    help='Directory containing workflow scripts', default='scripts')
parser.add_argument('--threads', dest='threads', type=int, 
                    help='Number of threads to use for processing')
parser.add_argument('--seurat-objects-fofn', dest='seurat_objects_fofn', type=str, 
                    help='Newline-delimited paths to the set of input seurat objects (file-of-filenames)')
parser.add_argument('--project-name', dest='project_name', type=str, 
                    help='Project name')
parser.add_argument('--output-metadata-file', dest='output_metadata_file', type=str, 
                    help='Output file to write metadata to')

# Parse the arguments
args = parser.parse_args()




sc.settings.verbosity = 1
sc.settings.figdir = 'plots/'
sc.settings.set_figure_params(dpi=100, fontsize=10, dpi_save=300, format='png', figsize=('12', '8')) # type: ignore


parser.add_argument('--adata-objects-fofn', dest='adata_objects_fofn', type=str, 
        help='Newline-delimited paths to the set of input seurat objects (file-of-filenames)')

metrics = ['n_genes_by_counts', 'total_counts', 'pct_counts_mt', 'pct_counts_rb', 'doublet_score']
sc.settings.verbosity = 1
sc.settings.figdir = 'plots/'
sc.settings.set_figure_params(dpi=100, fontsize=10, dpi_save=300, format='png', figsize=('12', '8')) # type: ignore

adatas = {}
top_genes = {}
for sample in samples:
    raw = sc.read_h5ad(sample) 
    adata = raw.copy()
    sc.pp.normalize_total(adata, target_sum=1e4)
    sc.pp.log1p(adata)
    sc.pp.highly_variable_genes(adata, flavor='seurat', n_top_genes=8000)

    ranked_genes = adata.var[adata.var.highly_variable].dispersions_norm.argsort().to_dict()   
    for k,v in ranked_genes.items():
        if k in top_genes:
            top_genes[k] += v
        else:
            top_genes[k] = v
    
    raw = minify_adata(raw)
    sample_name = sample.name.split("_")[1]
    adatas[sample_name] = raw

# we could subset to the top_genes here before concat if we have memory issues (e.g. whole dataset harmonization.)

adata = ad.concat(
        merge='same', uns_merge='same', index_unique='_',
        adatas=adatas
        )

for metric in metrics: # type: ignore
    sc.pl.violin(adata, keys=metric, size=0, save=''.join('_' + metric))


top_genes = pd.DataFrame(index=top_genes.keys(), columns=['rank'], data=top_genes.values())

#TODO: export top_genes and plots