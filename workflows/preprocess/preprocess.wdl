version 1.0

# Get read counts and generate a preprocessed Seurat object

import "../structs.wdl"

workflow preprocess {
	input {
		String project_id
		Array[Sample] samples

		File cellranger_reference_data

		Float soup_rate

		Boolean regenerate_preprocessed_seurat_objects

		String run_timestamp
		String raw_data_path_prefix
		String billing_project
		String container_registry
		Int multiome_container_revision
		String zones
	}

	String workflow_name = "preprocess"

	String cellranger_task_version = "1.1.0"
	String counts_to_seurat_task_version = "1.0.0"

	# Used in the manifest; doesn't influence output locations or whether the task needs to be rerun
	String workflow_version = "~{cellranger_task_version}_~{counts_to_seurat_task_version}"

	Array[Array[String]] workflow_info = [[run_timestamp, workflow_name, workflow_version]]

	String raw_data_path = "~{raw_data_path_prefix}/~{workflow_name}"

	scatter (sample_object in samples) {
		String cellranger_count_output = "~{raw_data_path}/cellranger/~{cellranger_task_version}/~{sample_object.sample_id}.raw_feature_bc_matrix.h5"
		String counts_to_seurat_output = "~{raw_data_path}/counts_to_seurat/~{counts_to_seurat_task_version}/~{sample_object.sample_id}.seurat_object.preprocessed_01.rds"
	}

	# For each sample, outputs an array of true/false: [cellranger_counts_complete, counts_to_seurat_complete]
	call check_output_files_exist {
		input:
			cellranger_count_output_files = cellranger_count_output,
			counts_to_seurat_output_files = counts_to_seurat_output,
			billing_project = billing_project,
			zones = zones
	}

	scatter (index in range(length(samples))) {
		Sample sample = samples[index]
		String cellranger_count_complete = check_output_files_exist.sample_preprocessing_complete[index][0]
		String counts_to_seurat_complete = check_output_files_exist.sample_preprocessing_complete[index][1]

		Array[String] project_sample_id = [project_id, sample.sample_id]

		String cellranger_raw_counts = "~{raw_data_path}/cellranger/~{cellranger_task_version}/~{sample.sample_id}.raw_feature_bc_matrix.h5"
		String cellranger_filtered_counts = "~{raw_data_path}/cellranger/~{cellranger_task_version}/~{sample.sample_id}.filtered_feature_bc_matrix.h5"
		String cellranger_molecule_info = "~{raw_data_path}/cellranger/~{cellranger_task_version}/~{sample.sample_id}.molecule_info.h5"
		String cellranger_metrics_csv = "~{raw_data_path}/cellranger/~{cellranger_task_version}/~{sample.sample_id}.metrics_summary.csv"
		String preprocessed_seurat_object = "~{raw_data_path}/counts_to_seurat/~{counts_to_seurat_task_version}/~{sample.sample_id}.seurat_object.preprocessed_01.rds"

		if (cellranger_count_complete == "false") {
			call cellranger_count {
				input:
					sample_id = sample.sample_id,
					fastq_R1s = sample.fastq_R1s,
					fastq_R2s = sample.fastq_R2s,
					fastq_I1s = sample.fastq_I1s,
					fastq_I2s = sample.fastq_I2s,
					cellranger_reference_data = cellranger_reference_data,
					raw_data_path = "~{raw_data_path}/cellranger/~{cellranger_task_version}",
					workflow_info = workflow_info,
					billing_project = billing_project,
					container_registry = container_registry,
					zones = zones
			}
		}

		File raw_counts_output = select_first([cellranger_count.raw_counts, cellranger_raw_counts]) #!FileCoercion
		File filtered_counts_output = select_first([cellranger_count.filtered_counts, cellranger_filtered_counts]) #!FileCoercion
		File molecule_info_output = select_first([cellranger_count.molecule_info, cellranger_molecule_info]) #!FileCoercion
		File metrics_csv_output = select_first([cellranger_count.metrics_csv, cellranger_metrics_csv]) #!FileCoercion

		if ((counts_to_seurat_complete == "false" && defined(sample.batch)) || regenerate_preprocessed_seurat_objects) {
			# Import counts and convert to a Seurat object
			call counts_to_seurat {
				input:
					sample_id = sample.sample_id,
					batch = select_first([sample.batch]),
					project_id = project_id,
					raw_counts = raw_counts_output, # !FileCoercion
					filtered_counts = filtered_counts_output, # !FileCoercion
					soup_rate = soup_rate,
					raw_data_path = "~{raw_data_path}/counts_to_seurat/~{counts_to_seurat_task_version}",
					workflow_info = workflow_info,
					billing_project = billing_project,
					container_registry = container_registry,
					multiome_container_revision = multiome_container_revision,
					zones = zones
			}
		}

		File seurat_object_output = select_first([counts_to_seurat.preprocessed_seurat_object, preprocessed_seurat_object]) #!FileCoercion
	}

	output {
		# Sample list
		Array[Array[String]] project_sample_ids = project_sample_id

		# Cellranger
		Array[File] raw_counts = raw_counts_output
		Array[File] filtered_counts = filtered_counts_output
		Array[File] molecule_info = molecule_info_output
		Array[File] metrics_csv = metrics_csv_output

		# Seurat counts
		Array[File] seurat_object = seurat_object_output

		Array[String] preprocessing_output_file_paths = flatten([
			raw_counts_output,
			filtered_counts_output,
			molecule_info_output,
			metrics_csv_output,
			seurat_object_output
		]) #!StringCoercion
	}
}

task check_output_files_exist {
	input {
		Array[String] cellranger_count_output_files
		Array[String] counts_to_seurat_output_files

		String billing_project
		String zones
	}

	command <<<
		set -euo pipefail

		while read -r output_files || [[ -n "${output_files}" ]]; do
			counts_file=$(echo "${output_files}" | cut -f 1)
			seurat_object=$(echo "${output_files}" | cut -f 2)

			if gsutil -u ~{billing_project} ls "${counts_file}"; then
				if gsutil -u ~{billing_project} ls "${seurat_object}"; then
					# If we find both the cellranger and seurat outputs, don't rerun anything
					echo -e "true\ttrue" >> sample_preprocessing_complete.tsv
				else
					# If we find the counts file but not the seurat object, just rerun seurat object generation
					echo -e "true\tfalse" >> sample_preprocessing_complete.tsv
				fi
			else
				# If we don't find cellranger output, we must also need to run (or rerun) preprocessing
				echo -e "false\tfalse" >> sample_preprocessing_complete.tsv
			fi
		done < <(paste ~{write_lines(cellranger_count_output_files)} ~{write_lines(counts_to_seurat_output_files)})
	>>>

	output {
		Array[Array[String]] sample_preprocessing_complete = read_tsv("sample_preprocessing_complete.tsv")
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

task counts_to_seurat {
	input {
		String sample_id
		String batch
		String project_id

		File raw_counts
		File filtered_counts

		Float soup_rate

		String raw_data_path
		Array[Array[String]] workflow_info
		String billing_project
		String container_registry
		Int multiome_container_revision
		String zones
	}

	Int disk_size = ceil(size([raw_counts, filtered_counts], "GB") * 2 + 20)
	# Memory scales with filtered_counts size
	Int mem_gb = ceil((size(filtered_counts, "GB") - 0.00132) / 0.001 + 10)

	command <<<
		set -euo pipefail

		/usr/bin/time \
		Rscript /opt/scripts/main/preprocess.R \
			--working-dir "$(pwd)" \
			--script-dir /opt/scripts \
			--sample-id ~{sample_id} \
			--batch ~{batch} \
			--project ~{project_id} \
			--raw-counts ~{raw_counts} \
			--filtered-counts ~{filtered_counts} \
			--soup-rate ~{soup_rate} \
			--output-seurat-object ~{sample_id}.seurat_object.preprocessed_01.rds

		upload_outputs \
			-b ~{billing_project} \
			-d ~{raw_data_path} \
			-i ~{write_tsv(workflow_info)} \
			-o "~{sample_id}.seurat_object.preprocessed_01.rds"
	>>>

	output {
		String preprocessed_seurat_object = "~{raw_data_path}/~{sample_id}.seurat_object.preprocessed_01.rds"
	}

	runtime {
		docker: "~{container_registry}/multiome:4a7fd84_~{multiome_container_revision}"
		cpu: 4
		memory: "~{mem_gb} GB"
		disks: "local-disk ~{disk_size} HDD"
		preemptible: 3
		bootDiskSizeGb: 20
		zones: zones
	}
}
