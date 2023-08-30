version 1.0

struct Sample {
	String sample_id
	String batch

	File fastq_R1
	File fastq_R2
}

workflow harmonized_pmdbs_analysis {
	input {
		String project_name
		Array[Sample] samples

		File cellranger_reference_data

		Float soup_rate = 0.20

		Int clustering_algorithm = 3
		Float clustering_resolution = 0.3
		File cell_type_markers_list

		Array[String] groups = ["sample", "batch", "seurat_clusters"]
		Array[String] features = ["doublet_scores", "nCount_RNA", "nFeature_RNA", "percent.mt", "percent.rb"]

		String container_registry
	}

	scatter (sample in samples) {
		call cellranger {
			input:
				sample_id = sample.sample_id,
				fastq_R1 = sample.fastq_R1,
				fastq_R2 = sample.fastq_R2,
				cellranger_reference_data = cellranger_reference_data,
				container_registry = container_registry
		}

		call preprocess {
			input:
				sample_id = sample.sample_id,
				batch = sample.batch,
				raw_counts = cellranger.raw_counts,
				filtered_counts = cellranger.filtered_counts,
				soup_rate = soup_rate,
				container_registry = container_registry
		}
	}

	call doublets {
		input:
			project_name = project_name,
			preprocessed_seurat_objects = preprocess.preprocessed_seurat_object,
			container_registry = container_registry
	}

	call plot_qc {
		input:
			project_name = project_name,
			unfiltered_metadata = doublets.unfiltered_metadata,
			container_registry = container_registry
	}

	scatter (preprocessed_seurat_object in preprocess.preprocessed_seurat_object) {
		call filter {
			input:
				preprocessed_seurat_object = preprocessed_seurat_object,
				unfiltered_metadata = doublets.unfiltered_metadata,
				container_registry = container_registry
		}

		call process {
			input:
				filtered_seurat_object = filter.filtered_seurat_object,
				container_registry = container_registry
		}
	}

	call harmony {
		input:
			project_name = project_name,
			normalized_seurat_objects = process.normalized_seurat_object,
			container_registry = container_registry
	}

	call neighbors {
		input:
			harmony_seurat_object = harmony.harmony_seurat_object,
			container_registry = container_registry
	}

	call umap {
		input:
			neighbors_seurat_object = neighbors.neighbors_seurat_object,
			container_registry = container_registry
	}

	call cluster {
		input:
			project_name = project_name,
			umap_seurat_object = umap.umap_seurat_object,
			clustering_algorithm = clustering_algorithm,
			clustering_resolution = clustering_resolution,
			cell_type_markers_list = cell_type_markers_list,
			container_registry = container_registry
	}

	call sctype {
		input:
			project_name = project_name,
			cluster_seurat_object = cluster.cluster_seurat_object,
			cell_type_markers_list = cell_type_markers_list,
			container_registry = container_registry
	}


	call plot_groups {
		input:
			project_name = project_name,
			metadata = sctype.metadata,
			groups = groups,
			container_registry = container_registry
	}

	call plot_features {
		input:
			project_name = project_name,
			metadata = sctype.metadata,
			features = features,
			container_registry = container_registry
	}

	output {
		# Cellranger
		Array[File?] raw_counts = cellranger.raw_counts
		Array[File?] filtered_counts = cellranger.filtered_counts
		Array[File?] molecule_info = cellranger.molecule_info
		Array[File?] cellranger_metrics_csv = cellranger.metrics_csv

		# QC plots
		File qc_violin_plots = plot_qc.qc_violin_plots
		File qc_umis_genes_plot = plot_qc.qc_umis_genes_plot

		# Final metadata
		File metadata = sctype.metadata

		# Group and feature plots
		Array[File] group_umap_plots = plot_groups.group_umap_plots
		Array[File] feature_umap_plots = plot_features.feature_umap_plots

		# Clustered seurat object
		File cluster_seurat_object = cluster.cluster_seurat_object
	}

	meta {
		description: "Harmonized postmortem-derived brain sequencing (PMDBS) workflow"
	}

	parameter_meta {
		project_name: {help: "Name of project"}
		samples: {help: "The set of samples and their associated reads and metadata"}
		cellranger_reference_data: {help: "Cellranger transcriptome reference data; see https://support.10xgenomics.com/single-cell-gene-expression/software/downloads/latest."}
		soup_rate: {help: "Dataset contamination rate fraction; used to remove mRNA contamination from the RNAseq data [0.2]"}
		clustering_algorithm: {help: "Clustering algorithm to use. [3]"}
		clustering_resolution: {help: "Clustering resolution to use during clustering. [0.3]"}
		cell_type_markers_list: {help: "Seurat object RDS file containing a list of major cell type markers; used to annotate clusters."}
		groups: {help: "Groups to produce umap plots for. ['sample', 'batch', 'seurat_clusters']"}
		features: {help: "Features to produce umap plots for. ['doublet_scores', 'nCount_RNA', 'nFeature_RNA', 'percent.mt', 'percent.rb']"}
		container_registry: {help: "Container registry where Docker images are hosted"}
	}
}

task cellranger {
	input {
		String sample_id

		File fastq_R1
		File fastq_R2

		File cellranger_reference_data

		String container_registry = "us-central1-docker.pkg.dev/dnastack-asap-parkinsons/workflow-images"
	}

	Int threads = 16
	# TODO not sure this amount of RAM is necessary - cellranger docs claim it is, but test runs using ~15 GB (may be missing part of the process..?)
	Int mem_gb = threads * 8
	Int disk_size = ceil(size([fastq_R1, fastq_R2], "GB") * 2 + 30)

	command <<<
		set -euo pipefail

		# Unpack refdata
		mkdir cellranger_refdata
		tar \
			-zxvf ~{cellranger_reference_data} \
			-C cellranger_refdata \
			--strip-components 1

		# Ensure fastqs are in the same directory
		mkdir fastqs
		ln -s ~{fastq_R1} ~{fastq_R2} fastqs/

		cellranger --version

		cellranger count \
			--id=~{sample_id} \
			--transcriptome="$(pwd)/cellranger_refdata" \
			--fastqs="$(pwd)/fastqs" \
			--localcores ~{threads} \
			--localmem ~{mem_gb - 4}

		# Rename outputs to include sample ID
		mv ~{sample_id}/outs/raw_feature_bc_matrix.h5 ~{sample_id}.raw_feature_bc_matrix.h5
		mv ~{sample_id}/outs/filtered_feature_bc_matrix.h5 ~{sample_id}.filtered_feature_bc_matrix.h5
		mv ~{sample_id}/outs/molecule_info.h5 ~{sample_id}.molecule_info.h5
		mv ~{sample_id}/outs/metrics_summary.csv ~{sample_id}.metrics_summary.csv
	>>>

	output {
		File raw_counts = "~{sample_id}.raw_feature_bc_matrix.h5"
		File filtered_counts = "~{sample_id}.filtered_feature_bc_matrix.h5"
		File molecule_info = "~{sample_id}.molecule_info.h5"
		File metrics_csv = "~{sample_id}.metrics_summary.csv"
	}

	runtime {
		docker: "~{container_registry}/cellranger:7.1.0"
		cpu: threads
		memory: "~{mem_gb} GB"
		disks: "local-disk ~{disk_size} HDD"
		preemptible: 3
	}
}

task preprocess {
	input {
		String sample_id
		String batch

		File raw_counts
		File filtered_counts

		Float soup_rate

		String container_registry
	}

	Int disk_size = ceil(size([raw_counts, filtered_counts], "GB") * 2 + 20)

	command <<<
		set -euo pipefail

		Rscript /opt/scripts/main/preprocess.R \
			--working-dir "$(pwd)" \
			--script-dir /opt/scripts \
			--sample-id ~{sample_id} \
			--batch ~{batch} \
			--raw-counts ~{raw_counts} \
			--filtered-counts ~{filtered_counts} \
			--soup-rate ~{soup_rate} \
			--output-seurat-object ~{sample_id}.seurat_object.preprocessed_01.rds
	>>>

	output {
		File preprocessed_seurat_object = "~{sample_id}.seurat_object.preprocessed_01.rds"
	}

	runtime {
		docker: "~{container_registry}/multiome:4a7fd84"
		cpu: 8
		memory: "12 GB"
		disks: "local-disk ~{disk_size} HDD"
		preemptible: 3
		bootDiskSizeGb: 20
	}
}

task doublets {
	input {
		String project_name
		Array[File] preprocessed_seurat_objects

		String container_registry
	}

	Int threads = 2
	Int disk_size = ceil(size(preprocessed_seurat_objects[0], "GB") * length(preprocessed_seurat_objects) * 2 + 30)

	command <<<
		set -euo pipefail

		Rscript /opt/scripts/main/gmm_doublet_calling.R \
			--working-dir "$(pwd)" \
			--script-dir /opt/scripts \
			--threads ~{threads} \
			--seurat-objects-fofn ~{write_lines(preprocessed_seurat_objects)} \
			--project-name ~{project_name} \
			--output-metadata-file ~{project_name}.unfiltered_metadata.csv
	>>>

	output {
		File unfiltered_metadata = "~{project_name}.unfiltered_metadata.csv"
	}

	runtime {
		docker: "~{container_registry}/multiome:4a7fd84"
		cpu: threads
		memory: "4 GB"
		disks: "local-disk ~{disk_size} HDD"
		preemptible: 3
		bootDiskSizeGb: 20
	}
}

task plot_qc {
	input {
		String project_name
		File unfiltered_metadata

		String container_registry
	}

	Int threads = 2
	Int disk_size = ceil(size(unfiltered_metadata, "GB") * 2 + 20)

	command <<<
		set -euo pipefail

		Rscript /opt/scripts/main/plot_qc_metrics.R \
			--working-dir "$(pwd)" \
			--script-dir /opt/scripts \
			--threads ~{threads} \
			--metadata ~{unfiltered_metadata} \
			--project-name ~{project_name} \
			--output-violin-plots ~{project_name}.qc.violin_plots.pdf \
			--output-umis-genes-plot ~{project_name}.qc.umis_genes_plot.pdf
	>>>

	output {
		File qc_violin_plots = "~{project_name}.qc.violin_plots.pdf"
		File qc_umis_genes_plot = "~{project_name}.qc.umis_genes_plot.pdf"
	}

	runtime {
		docker: "~{container_registry}/multiome:4a7fd84"
		cpu: threads
		memory: "4 GB"
		disks: "local-disk ~{disk_size} HDD"
		preemptible: 3
		bootDiskSizeGb: 20
	}
}

task filter {
	input {
		File preprocessed_seurat_object
		File unfiltered_metadata

		String container_registry
	}

	String seurat_object_basename = basename(preprocessed_seurat_object, "_01.rds")
	Int disk_size = ceil(size(preprocessed_seurat_object, "GB") * 2 + 20)

	command <<<
		set -euo pipefail

		Rscript /opt/scripts/main/filter.R \
			--working-dir "$(pwd)" \
			--script-dir /opt/scripts \
			--seurat-object ~{preprocessed_seurat_object} \
			--metadata ~{unfiltered_metadata} \
			--output-seurat-object ~{seurat_object_basename}_filtered_02.rds
	>>>

	output {
		File filtered_seurat_object = "~{seurat_object_basename}_filtered_02.rds"
	}

	runtime {
		docker: "~{container_registry}/multiome:4a7fd84"
		cpu: 2
		memory: "4 GB"
		disks: "local-disk ~{disk_size} HDD"
		preemptible: 3
		bootDiskSizeGb: 20
	}
}

task process {
	input {
		File filtered_seurat_object

		String container_registry
	}

	Int threads = 2
	String seurat_object_basename = basename(filtered_seurat_object, "_02.rds")
	Int disk_size = ceil(size(filtered_seurat_object, "GB") * 2 + 20)

	command <<<
		set -euo pipefail

		Rscript /opt/scripts/main/process.R \
			--working-dir "$(pwd)" \
			--script-dir /opt/scripts \
			--threads ~{threads} \
			--seurat-object ~{filtered_seurat_object} \
			--output-seurat-object ~{seurat_object_basename}_normalized_03.rds
	>>>

	output {
		File normalized_seurat_object = "~{seurat_object_basename}_normalized_03.rds"
	}

	runtime {
		docker: "~{container_registry}/multiome:4a7fd84"
		cpu: threads
		memory: "4 GB"
		disks: "local-disk ~{disk_size} HDD"
		preemptible: 3
		bootDiskSizeGb: 20
	}
}

task harmony {
	input {
		String project_name
		Array[File] normalized_seurat_objects

		String container_registry
	}

	# TODO Seems to only use ~4 threads; following snakemake for now
	Int threads = 8
	Int disk_size = ceil(size(normalized_seurat_objects[0], "GB") * length(normalized_seurat_objects) * 2 + 30)

	command <<<
		set -euo pipefail

		Rscript /opt/scripts/main/harmony.R \
			--working-dir "$(pwd)" \
			--script-dir /opt/scripts \
			--threads ~{threads} \
			--seurat-objects-fofn ~{write_lines(normalized_seurat_objects)} \
			--output-seurat-object ~{project_name}.seurat_object.harmony_integrated_04.rds
	>>>

	output {
		File harmony_seurat_object = "~{project_name}.seurat_object.harmony_integrated_04.rds"
	}

	runtime {
		docker: "~{container_registry}/multiome:4a7fd84"
		cpu: threads
		memory: "4 GB"
		disks: "local-disk ~{disk_size} HDD"
		preemptible: 3
		bootDiskSizeGb: 20
	}
}

task neighbors {
	input {
		File harmony_seurat_object

		String container_registry
	}

	String harmony_seurat_object_basename = basename(harmony_seurat_object, "_04.rds")
	Int disk_size = ceil(size(harmony_seurat_object, "GB") * 2 + 20)

	command <<<
		set -euo pipefail

		Rscript /opt/scripts/main/find_neighbors.R \
			--working-dir "$(pwd)" \
			--script-dir /opt/scripts \
			--seurat-object ~{harmony_seurat_object} \
			--output-seurat-object ~{harmony_seurat_object_basename}_neighbors_05.rds
	>>>

	output {
		File neighbors_seurat_object = "~{harmony_seurat_object_basename}_neighbors_05.rds"
	}

	runtime {
		docker: "~{container_registry}/multiome:4a7fd84"
		cpu: 2
		memory: "4 GB"
		disks: "local-disk ~{disk_size} HDD"
		preemptible: 3
		bootDiskSizeGb: 20
	}
}

task umap {
	input {
		File neighbors_seurat_object

		String container_registry
	}

	String neighbors_seurat_object_basename = basename(neighbors_seurat_object, "_05.rds")
	Int disk_size = ceil(size(neighbors_seurat_object, "GB") * 2 + 20)

	command <<<
		set -euo pipefail

		Rscript /opt/scripts/main/umap.R \
			--working-dir "$(pwd)" \
			--script-dir /opt/scripts \
			--seurat-object ~{neighbors_seurat_object} \
			--output-seurat-object ~{neighbors_seurat_object_basename}_umap_06.rds
	>>>

	output {
		File umap_seurat_object = "~{neighbors_seurat_object_basename}_umap_06.rds"
	}

	runtime {
		docker: "~{container_registry}/multiome:4a7fd84"
		cpu: 2
		memory: "4 GB"
		disks: "local-disk ~{disk_size} HDD"
		preemptible: 3
		bootDiskSizeGb: 20
	}
}

task cluster {
	input {
		String project_name
		File umap_seurat_object

		Int clustering_algorithm
		Float clustering_resolution
		File cell_type_markers_list

		String container_registry
	}

	# TODO only used 1 core
	Int threads = 8
	String umap_seurat_object_basename = basename(umap_seurat_object, "_06.rds")
	Int disk_size = ceil((size(umap_seurat_object, "GB") + size(cell_type_markers_list, "GB")) * 2 + 20)

	command <<<
		set -euo pipefail

		Rscript /opt/scripts/main/clustering.R \
			--working-dir "$(pwd)" \
			--script-dir /opt/scripts \
			--threads ~{threads} \
			--seurat-object ~{umap_seurat_object} \
			--clustering-algorithm ~{clustering_algorithm} \
			--clustering-resolution ~{clustering_resolution} \
			--cell-type-markers-list ~{cell_type_markers_list} \
			--output-cell-type-plot ~{project_name}.major_type_module_umap.pdf \
			--output-seurat-object ~{umap_seurat_object_basename}_cluster_07.rds
	>>>

	output {
		File major_cell_type_plot = "~{project_name}.major_type_module_umap.pdf"
		File cluster_seurat_object = "~{umap_seurat_object_basename}_cluster_07.rds"
	}

	runtime {
		docker: "~{container_registry}/multiome:4a7fd84"
		cpu: threads
		memory: "4 GB"
		disks: "local-disk ~{disk_size} HDD"
		preemptible: 3
		bootDiskSizeGb: 20
	}
}

task sctype {
	input {
		String project_name
		File cluster_seurat_object

		File cell_type_markers_list

		String container_registry
	}

	# TODO uses 2 cores
	Int threads = 8
	Int mem_gb = threads
	Int disk_size = ceil(size(cell_type_markers_list, "GB") * 2 + 20)

	command <<<
		set -euo pipefail

		Rscript /opt/scripts/main/annotate_clusters.R \
			--working-dir "$(pwd)" \
			--script-dir /opt/scripts \
			--threads ~{threads} \
			--seurat-object ~{cluster_seurat_object} \
			--cell-type-markers-list ~{cell_type_markers_list} \
			--output-metadata-file ~{project_name}.final_metadata.csv
	>>>

	output {
		File metadata = "~{project_name}.final_metadata.csv"
	}

	runtime {
		docker: "~{container_registry}/multiome:4a7fd84"
		cpu: threads
		memory: "~{mem_gb} GB"
		disks: "local-disk ~{disk_size} HDD"
		preemptible: 3
		bootDiskSizeGb: 20
	}
}

task plot_groups {
	input {
		String project_name
		File metadata

		Array[String] groups

		String container_registry
	}

	Int disk_size = ceil(size(metadata, "GB") * 2 + 20)

	command <<<
		set -euo pipefail

		while read -r group || [[ -n "${group}" ]]; do
			Rscript /opt/scripts/main/plot_groups.R \
				--working-dir "$(pwd)" \
				--metadata ~{metadata} \
				--group "${group}" \
				--output-group-umap-plot "~{project_name}.${group}_group_umap.pdf"
			done < ~{write_lines(groups)}
	>>>

	output {
		Array[File] group_umap_plots = glob("~{project_name}.*_group_umap.pdf")
	}

	runtime {
		docker: "~{container_registry}/multiome:4a7fd84"
		cpu: 2
		memory: "4 GB"
		disks: "local-disk ~{disk_size} HDD"
		preemptible: 3
		bootDiskSizeGb: 20
	}
}

task plot_features {
	input {
		String project_name
		File metadata

		Array[String] features

		String container_registry
	}

	Int disk_size = ceil(size(metadata, "GB") * 2 + 20)

	command <<<
		set -euo pipefail

		while read -r feature || [[ -n "${feature}" ]]; do
			Rscript /opt/scripts/main/plot_features.R \
				--working-dir "$(pwd)" \
				--metadata ~{metadata} \
				--feature "${feature}" \
				--output-feature-umap-plot "~{project_name}.${feature}_feature_umap.pdf"
		done < ~{write_lines(features)}
	>>>

	output {
		Array[File] feature_umap_plots = glob("~{project_name}.*_feature_umap.pdf")
	}

	runtime {
		docker: "~{container_registry}/multiome:4a7fd84"
		cpu: 2
		memory: "4 GB"
		disks: "local-disk ~{disk_size} HDD"
		preemptible: 3
		bootDiskSizeGb: 20
	}
}
