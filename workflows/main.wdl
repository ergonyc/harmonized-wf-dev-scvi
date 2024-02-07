version 1.0

# Harmonized workflow entrypoint

import "structs.wdl"

workflow harmonized_pmdbs_analysis {
	input {
		String cohort_id
		Array[Project] projects

		File cellranger_reference_data

		Boolean regenerate_preprocessed_adata_objects = false

		Boolean run_cross_team_cohort_analysis = false
		String cohort_raw_data_bucket
		Array[String] cohort_staging_data_buckets

		String container_registry
		String zones = "us-central1-c us-central1-f"
	}

	# Task and subworkflow versions
	String cellranger_task_version = "v1.1.0"

	String workflow_execution_path = "workflow_execution"

	call get_workflow_metadata {
		input:
			zones = zones
	}

	scatter (project in projects) {
		scatter (sample_object in project.samples) {
			String cellranger_count_output = "~{project.raw_data_bucket}/~{workflow_execution_path}/cellranger/~{cellranger_task_version}/~{sample_object.sample_id}.raw_feature_bc_matrix.h5"
		}

		# For each sample, outputs an array of true/false
		call check_output_files_exist {
		input:
			cellranger_count_output_files = cellranger_count_output,
			billing_project = get_workflow_metadata.billing_project,
			zones = zones
		}

		scatter (index in range(length(project.samples))) {
			Sample sample = project.samples[index]
			String cellranger_count_complete = check_output_files_exist.sample_cellranger_complete[index][0]

			Array[String] project_sample_id = [project.project_id, sample.sample_id]

			String cellranger_raw_counts = "~{project.raw_data_bucket}/~{workflow_execution_path}/cellranger/~{cellranger_task_version}/~{sample.sample_id}.raw_feature_bc_matrix.h5"
			String cellranger_filtered_counts = "~{project.raw_data_bucket}/~{workflow_execution_path}/cellranger/~{cellranger_task_version}/~{sample.sample_id}.filtered_feature_bc_matrix.h5"
			String cellranger_molecule_info = "~{project.raw_data_bucket}/~{workflow_execution_path}/cellranger/~{cellranger_task_version}/~{sample.sample_id}.molecule_info.h5"
			String cellranger_metrics_csv = "~{project.raw_data_bucket}/~{workflow_execution_path}/cellranger/~{cellranger_task_version}/~{sample.sample_id}.metrics_summary.csv"

			if (cellranger_count_complete == "false") {
				call cellranger_count {
					input:
						sample_id = sample.sample_id,
						fastq_R1s = sample.fastq_R1s,
						fastq_R2s = sample.fastq_R2s,
						fastq_I1s = sample.fastq_I1s,
						fastq_I2s = sample.fastq_I2s,
						cellranger_reference_data = cellranger_reference_data,
						raw_data_path = "~{project.raw_data_bucket}/workflow_execution/cellranger/~{cellranger_task_version}",
						workflow_info = [[get_workflow_metadata.timestamp, "cellranger", cellranger_task_version]],
						billing_project = get_workflow_metadata.billing_project,
						container_registry = container_registry,
						zones = zones
				}
			}

			File raw_counts_output = select_first([cellranger_count.raw_counts, cellranger_raw_counts]) #!FileCoercion
			File filtered_counts_output = select_first([cellranger_count.filtered_counts, cellranger_filtered_counts]) #!FileCoercion
			File molecule_info_output = select_first([cellranger_count.molecule_info, cellranger_molecule_info]) #!FileCoercion
			File metrics_csv_output = select_first([cellranger_count.metrics_csv, cellranger_metrics_csv]) #!FileCoercion
		}
	}

	output {
		# Sample list
		Array[Array[Array[String]]] project_sample_ids = project_sample_id

		# Cellranger
		Array[Array[File]] raw_counts = raw_counts_output
		Array[Array[File]] filtered_counts = filtered_counts_output
		Array[Array[File]] molecule_info = molecule_info_output
		Array[Array[File]] metrics_csvs = metrics_csv_output
	}

	meta {
		description: "Harmonized postmortem-derived brain sequencing (PMDBS) workflow"
	}

	parameter_meta {
		cohort_id: {help: "Name of the cohort; used to name output files during cross-team cohort analysis."}
		projects: {help: "The project ID, set of samples and their associated reads and metadata, output bucket locations, and whether or not to run project-level cohort analysis."}
		cellranger_reference_data: {help: "Cellranger transcriptome reference data; see https://support.10xgenomics.com/single-cell-gene-expression/software/downloads/latest."}
		run_cross_team_cohort_analysis: {help: "Whether to run downstream harmonization steps on all samples across projects. If set to false, only preprocessing steps (cellranger and generating the initial seurat object(s)) will run for samples. [false]"}
		cohort_raw_data_bucket: {help: "Bucket to upload cross-team cohort intermediate files to."}
		cohort_staging_data_buckets: {help: "Set of buckets to stage cross-team cohort analysis outputs in."}
		container_registry: {help: "Container registry where workflow Docker images are hosted."}
		zones: {help: "Space-delimited set of GCP zones to spin up compute in."}
	}
}

task get_workflow_metadata {
	input {
		String zones
	}

	command <<<
		set -euo pipefail

		# UTC timestamp for the running workflow
		date -u +"%FT%H-%M-%SZ" > timestamp.txt

		# Billing project to use for file requests (matches the billing project used for compute)
		curl "http://metadata.google.internal/computeMetadata/v1/project/project-id" \
				-H "Metadata-Flavor: Google" \
		> billing_project.txt
	>>>

	output {
		String timestamp = read_string("timestamp.txt")
		String billing_project = read_string("billing_project.txt")
	}

	runtime {
		docker: "gcr.io/google.com/cloudsdktool/google-cloud-cli:444.0.0-slim"
		cpu: 2
		memory: "4 GB"
		disks: "local-disk 10 HDD"
		preemptible: 3
		zones: zones
	}
}

task check_output_files_exist {
	input {
		Array[String] cellranger_count_output_files

		String billing_project
		String zones
	}

	command <<<
		set -euo pipefail

		while read -r output_files || [[ -n "${output_files}" ]]; do 
			if gsutil -u ~{billing_project} ls "${output_files}"; then
				echo "true" >> sample_cellranger_complete.tsv
			else
				echo "false" >> sample_cellranger_complete.tsv
			fi
		done < ~{write_lines(cellranger_count_output_files)}
	>>>

	output {
		Array[Array[String]] sample_cellranger_complete = read_tsv("sample_cellranger_complete.tsv")
	}

	runtime {
		docker: "gcr.io/google.com/cloudsdktool/google-cloud-cli:444.0.0-slim"
		cpu: 2
		memory: "4 GB"
		disks: "local-disk 20 HDD"
		preemptible: 3
		zones: zones
	}
}

task cellranger_count {
	input {
		String sample_id

		Array[File] fastq_R1s
		Array[File] fastq_R2s
		Array[File] fastq_I1s
		Array[File] fastq_I2s

		File cellranger_reference_data

		String raw_data_path
		Array[Array[String]] workflow_info
		String billing_project
		String container_registry
		String zones
	}

	Int threads = 16
	Int disk_size = ceil((size(fastq_R1s, "GB") + size(fastq_R2s, "GB") + size(fastq_I1s, "GB") + size(fastq_I2s, "GB") + size(cellranger_reference_data, "GB")) * 4 + 50)
	Int mem_gb = 24

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
		while read -r fastq || [[ -n "${fastq}" ]]; do
			if [[ -n "${fastq}" ]]; then
				validated_fastq_name=$(fix_fastq_names --fastq "${fastq}" --sample-id "~{sample_id}")
				if [[ -e "fastqs/${validated_fastq_name}" ]]; then
					echo "[ERROR] Something's gone wrong with fastq renaming; trying to create fastq [${validated_fastq_name}] but it already exists. Exiting."
					exit 1
				else
					ln -s "${fastq}" "fastqs/${validated_fastq_name}"
				fi
			fi
		done < <(cat \
			~{write_lines(fastq_R1s)} \
			~{write_lines(fastq_R2s)} \
			~{write_lines(fastq_I1s)} \
			~{write_lines(fastq_I2s)})

		cellranger --version

		/usr/bin/time \
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

		upload_outputs \
			-b ~{billing_project} \
			-d ~{raw_data_path} \
			-i ~{write_tsv(workflow_info)} \
			-o "~{sample_id}.raw_feature_bc_matrix.h5" \
			-o "~{sample_id}.filtered_feature_bc_matrix.h5" \
			-o "~{sample_id}.molecule_info.h5" \
			-o "~{sample_id}.metrics_summary.csv"
	>>>

	output {
		String raw_counts = "~{raw_data_path}/~{sample_id}.raw_feature_bc_matrix.h5"
		String filtered_counts = "~{raw_data_path}/~{sample_id}.filtered_feature_bc_matrix.h5"
		String molecule_info = "~{raw_data_path}/~{sample_id}.molecule_info.h5"
		String metrics_csv = "~{raw_data_path}/~{sample_id}.metrics_summary.csv"
	}

	runtime {
		docker: "~{container_registry}/cellranger:7.1.0"
		cpu: threads
		memory: "~{mem_gb} GB"
		disks: "local-disk ~{disk_size} HDD"
		preemptible: 3
		zones: zones
	}
}
