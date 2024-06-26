## Copyright Broad Institute, 2018
## 
## This WDL implements the joint discovery and VQSR filtering portion of the GATK 
## Best Practices (June 2016) for germline SNP and Indel discovery in human 
## whole-genome sequencing (WGS) and exome sequencing data.
##
## Requirements/expectations :
## - One or more GVCFs produced by HaplotypeCaller in GVCF mode 
## - Bare minimum 1 WGS sample or 30 Exome samples. Gene panels are not supported.
##
## Outputs :
## - A VCF file and its index, filtered using variant quality score recalibration 
##   (VQSR) with genotypes for all samples present in the input VCF. All sites that 
##   are present in the input VCF are retained; filtered sites are annotated as such 
##   in the FILTER field.
##
## Note about VQSR wiring :
## The SNP and INDEL models are built in parallel, but then the corresponding 
## recalibrations are applied in series. Because the INDEL model is generally ready 
## first (because there are fewer indels than SNPs) we set INDEL recalibration to 
## be applied first to the input VCF, while the SNP model is still being built. By 
## the time the SNP model is available, the indel-recalibrated file is available to 
## serve as input to apply the SNP recalibration. If we did it the other way around, 
## we would have to wait until the SNP recal file was available despite the INDEL 
## recal file being there already, then apply SNP recalibration, then apply INDEL 
## recalibration. This would lead to a longer wall clock time for complete workflow 
## execution. Wiring the INDEL recalibration to be applied first solves the problem.
##
## Cromwell version support 
## - Successfully tested on v31
## - Does not work on versions < v23 due to output syntax
##
## Runtime parameters are optimized for Broad's Google Cloud Platform implementation. 
## For program versions, see docker containers. 
##
## LICENSING : 
## This script is released under the WDL source code license (BSD-3) (see LICENSE in 
## https://github.com/broadinstitute/wdl). Note however that the programs it calls may 
## be subject to different licenses. Users are responsible for checking that they are
## authorized to run all programs before running this script. Please see the docker 
## page at https://hub.docker.com/r/broadinstitute/genomes-in-the-cloud/ for detailed
## licensing information pertaining to the included programs.

## Allow VM can be configured at different zones

workflow JointGenotyping {
  # mbookman: Allow for passing a project ID such that ImportGVCFs
  # can support requester pays buckets.
  String user_project_id

  # Input Sample
  String callset_name
  File sample_name_map
  String sample_expression

  # Reference and Resources
  File ref_fasta
  File ref_fasta_index
  File ref_dict

  File dbsnp_vcf
  File dbsnp_vcf_index
  
  Array[String] snp_recalibration_tranche_values
  Array[String] snp_recalibration_annotation_values
  Array[String] indel_recalibration_tranche_values
  Array[String] indel_recalibration_annotation_values

  File eval_interval_list
  File hapmap_resource_vcf
  File hapmap_resource_vcf_index
  File omni_resource_vcf
  File omni_resource_vcf_index
  File one_thousand_genomes_resource_vcf
  File one_thousand_genomes_resource_vcf_index
  File mills_resource_vcf
  File mills_resource_vcf_index
  File axiomPoly_resource_vcf
  File axiomPoly_resource_vcf_index
  File dbsnp_resource_vcf = dbsnp_vcf
  File dbsnp_resource_vcf_index = dbsnp_vcf_index
  
  File unpadded_intervals_file

  # Runtime attributes
  String? gatk_docker_override
  String gatk_docker = select_first([gatk_docker_override, "broadinstitute/gatk:4.2.6.1"])
  String? gatk_path_override
  String gatk_path = select_first([gatk_path_override, "/gatk/gatk"])
  String runtime_zones

  Int? small_disk_override
  Int small_disk = select_first([small_disk_override, "100"])
  Int? medium_disk_override
  Int medium_disk = select_first([medium_disk_override, "200"])
  Int? large_disk_override
  Int large_disk = select_first([large_disk_override, "300"])
  Int? huge_disk_override
  Int huge_disk = select_first([huge_disk_override, "400"])

  # mbookman: Add support for maxRetries, as shards can arbitrarily fail
  # due to Pipelines API Error 10
  # See https://support.terra.bio/hc/en-us/community/posts/360046714292.
  String? max_retries_override
  Int max_retries = select_first([max_retries_override, "2"])
  String? preemptible_tries_override
  Int preemptible_tries = select_first([preemptible_tries_override, "3"])

  # ExcessHet is a phred-scaled p-value. We want a cutoff of anything more extreme
  # than a z-score of -4.5 which is a p-value of 3.4e-06, which phred-scaled is 54.69
  Float excess_het_threshold = 54.69
  Float snp_filter_level
  Float indel_filter_level
  Int SNP_VQSR_downsampleFactor

  Int num_of_original_intervals = length(read_lines(unpadded_intervals_file))
  Int num_gvcfs = length(read_lines(sample_name_map))

  # Make a 2.5:1 interval number to samples in callset ratio interval list
  Int possible_merge_count = floor(num_of_original_intervals / num_gvcfs / 2.5)
  # Hard-coding merge_count to 3 as a test to resolve issue with stalled workflow
  # Int merge_count = if possible_merge_count > 1 then possible_merge_count else 1
  Int merge_count = 3
  
  call DynamicallyCombineIntervals {
    input:
      intervals = unpadded_intervals_file,
      merge_count = merge_count,
      max_retries = max_retries,
      preemptible_tries = preemptible_tries,
      runtime_zones = runtime_zones
  }

  Array[String] unpadded_intervals = read_lines(DynamicallyCombineIntervals.output_intervals)

  scatter (idx in range(length(unpadded_intervals))) {
    # the batch_size value was carefully chosen here as it
    # is the optimal value for the amount of memory allocated
    # within the task; please do not change it without consulting
    # the Hellbender (GATK engine) team!
    call ImportGVCFs {
      input:
        user_project_id = user_project_id,
        sample_name_map = sample_name_map,
        interval = unpadded_intervals[idx],
        workspace_dir_name = "genomicsdb",
        disk_size = medium_disk,
        batch_size = 50,
        docker = gatk_docker,
        gatk_path = gatk_path,
        max_retries = max_retries,
        preemptible_tries = preemptible_tries,
        runtime_zones = runtime_zones
    }

    call GenotypeGVCFs {
      input:
        workspace_tar = ImportGVCFs.output_genomicsdb,
        interval = unpadded_intervals[idx],
        output_vcf_filename = "output.vcf.gz",
        ref_fasta = ref_fasta,
        ref_fasta_index = ref_fasta_index,
        ref_dict = ref_dict,
        dbsnp_vcf = dbsnp_vcf,
        disk_size = medium_disk,
        docker = gatk_docker,
        gatk_path = gatk_path,
        max_retries = max_retries,
        preemptible_tries = preemptible_tries,
        runtime_zones = runtime_zones
    }

    call HardFilterAndMakeSitesOnlyVcf {
      input:
        vcf = GenotypeGVCFs.output_vcf,
        vcf_index = GenotypeGVCFs.output_vcf_index,
        excess_het_threshold = excess_het_threshold,
        variant_filtered_vcf_filename = callset_name + "." + idx + ".variant_filtered.vcf.gz",
        sites_only_vcf_filename = callset_name + "." + idx + ".sites_only.variant_filtered.vcf.gz",
        disk_size = medium_disk,
        docker = gatk_docker,
        gatk_path = gatk_path,
        max_retries = max_retries,
        preemptible_tries = preemptible_tries,
        runtime_zones = runtime_zones
    }
  }

  call GatherVcfs as SitesOnlyGatherVcf {
    input:
      input_vcfs_fofn = write_lines(HardFilterAndMakeSitesOnlyVcf.sites_only_vcf),
      output_vcf_name = callset_name + ".sites_only.vcf.gz",
      disk_size = medium_disk,
      docker = gatk_docker,
      gatk_path = gatk_path,
      max_retries = max_retries,
      preemptible_tries = preemptible_tries,
      runtime_zones = runtime_zones
  }

  call IndelsVariantRecalibrator {
    input:
      sites_only_variant_filtered_vcf = SitesOnlyGatherVcf.output_vcf,
      sites_only_variant_filtered_vcf_index = SitesOnlyGatherVcf.output_vcf_index,
      recalibration_filename = callset_name + ".indels.recal",
      tranches_filename = callset_name + ".indels.tranches",
      recalibration_tranche_values = indel_recalibration_tranche_values,
      recalibration_annotation_values = indel_recalibration_annotation_values,
      mills_resource_vcf = mills_resource_vcf,
      mills_resource_vcf_index = mills_resource_vcf_index,
      axiomPoly_resource_vcf = axiomPoly_resource_vcf,
      axiomPoly_resource_vcf_index = axiomPoly_resource_vcf_index,
      dbsnp_resource_vcf = dbsnp_resource_vcf,
      dbsnp_resource_vcf_index = dbsnp_resource_vcf_index,
      disk_size = small_disk,
      docker = gatk_docker,
      gatk_path = gatk_path,
      max_retries = max_retries,
      preemptible_tries = preemptible_tries,
      runtime_zones = runtime_zones
  }

  if (num_gvcfs > 10500) {
  call SNPsVariantRecalibratorCreateModel {
      input:
        sites_only_variant_filtered_vcf = SitesOnlyGatherVcf.output_vcf,
        sites_only_variant_filtered_vcf_index = SitesOnlyGatherVcf.output_vcf_index,
        recalibration_filename = callset_name + ".snps.recal",
        tranches_filename = callset_name + ".snps.tranches",
        recalibration_tranche_values = snp_recalibration_tranche_values,
        recalibration_annotation_values = snp_recalibration_annotation_values,
        downsampleFactor = SNP_VQSR_downsampleFactor,
        model_report_filename = callset_name + ".snps.model.report",
        hapmap_resource_vcf = hapmap_resource_vcf,
        hapmap_resource_vcf_index = hapmap_resource_vcf_index,
        omni_resource_vcf = omni_resource_vcf,
        omni_resource_vcf_index = omni_resource_vcf_index,
        one_thousand_genomes_resource_vcf = one_thousand_genomes_resource_vcf,
        one_thousand_genomes_resource_vcf_index = one_thousand_genomes_resource_vcf_index,
        dbsnp_resource_vcf = dbsnp_resource_vcf,
        dbsnp_resource_vcf_index = dbsnp_resource_vcf_index,
        disk_size = small_disk,
        docker = gatk_docker,
        gatk_path = gatk_path,
        max_retries = max_retries,
        preemptible_tries = preemptible_tries,
        runtime_zones = runtime_zones
    }

  scatter (idx in range(length(HardFilterAndMakeSitesOnlyVcf.sites_only_vcf))) {
    call SNPsVariantRecalibrator as SNPsVariantRecalibratorScattered {
      input:
        sites_only_variant_filtered_vcf = HardFilterAndMakeSitesOnlyVcf.sites_only_vcf[idx],
        sites_only_variant_filtered_vcf_index = HardFilterAndMakeSitesOnlyVcf.sites_only_vcf_index[idx],
        recalibration_filename = callset_name + ".snps." + idx + ".recal",
        tranches_filename = callset_name + ".snps." + idx + ".tranches",
        recalibration_tranche_values = snp_recalibration_tranche_values,
        recalibration_annotation_values = snp_recalibration_annotation_values,
        model_report = SNPsVariantRecalibratorCreateModel.model_report,
        hapmap_resource_vcf = hapmap_resource_vcf,
        hapmap_resource_vcf_index = hapmap_resource_vcf_index,
        omni_resource_vcf = omni_resource_vcf,
        omni_resource_vcf_index = omni_resource_vcf_index,
        one_thousand_genomes_resource_vcf = one_thousand_genomes_resource_vcf,
        one_thousand_genomes_resource_vcf_index = one_thousand_genomes_resource_vcf_index,
        dbsnp_resource_vcf = dbsnp_resource_vcf,
        dbsnp_resource_vcf_index = dbsnp_resource_vcf_index,
        disk_size = small_disk,
        docker = gatk_docker,
        gatk_path = gatk_path,
        max_retries = max_retries,
        preemptible_tries = preemptible_tries,
        runtime_zones = runtime_zones
      }
    }
    call GatherTranches as SNPGatherTranches {
        input:
          input_fofn = write_lines(SNPsVariantRecalibratorScattered.tranches),
          output_filename = callset_name + ".snps.gathered.tranches",
          disk_size = small_disk,
          docker = gatk_docker,
          gatk_path = gatk_path,
          max_retries = max_retries,
          preemptible_tries = preemptible_tries,
          runtime_zones = runtime_zones
      }
  }


  if (num_gvcfs <= 10500){
    call SNPsVariantRecalibrator as SNPsVariantRecalibratorClassic {
      input:
          sites_only_variant_filtered_vcf = SitesOnlyGatherVcf.output_vcf,
          sites_only_variant_filtered_vcf_index = SitesOnlyGatherVcf.output_vcf_index,
          recalibration_filename = callset_name + ".snps.recal",
          tranches_filename = callset_name + ".snps.tranches",
          recalibration_tranche_values = snp_recalibration_tranche_values,
          recalibration_annotation_values = snp_recalibration_annotation_values,
          hapmap_resource_vcf = hapmap_resource_vcf,
          hapmap_resource_vcf_index = hapmap_resource_vcf_index,
          omni_resource_vcf = omni_resource_vcf,
          omni_resource_vcf_index = omni_resource_vcf_index,
          one_thousand_genomes_resource_vcf = one_thousand_genomes_resource_vcf,
          one_thousand_genomes_resource_vcf_index = one_thousand_genomes_resource_vcf_index,
          dbsnp_resource_vcf = dbsnp_resource_vcf,
          dbsnp_resource_vcf_index = dbsnp_resource_vcf_index,
          disk_size = small_disk,
          docker = gatk_docker,
          gatk_path = gatk_path,
          runtime_zones = runtime_zones,

          # mbookman: This is a single gating node for the next batch of
          # sharded steps. Prefer not to use preemptible VMs here.
          max_retries = 1,
          preemptible_tries = 0
    }
  }

  # For small callsets (fewer than 1000 samples) we can gather the VCF shards and collect metrics directly.
  # For anything larger, we need to keep the VCF sharded and gather metrics collected from them.
  Boolean is_small_callset = num_gvcfs <= 1000

  scatter (idx in range(length(HardFilterAndMakeSitesOnlyVcf.variant_filtered_vcf))) {
    call ApplyRecalibration {
      input:
        recalibrated_vcf_filename = callset_name + ".filtered." + idx + ".vcf.gz",
        input_vcf = HardFilterAndMakeSitesOnlyVcf.variant_filtered_vcf[idx],
        input_vcf_index = HardFilterAndMakeSitesOnlyVcf.variant_filtered_vcf_index[idx],
        indels_recalibration = IndelsVariantRecalibrator.recalibration,
        indels_recalibration_index = IndelsVariantRecalibrator.recalibration_index,
        indels_tranches = IndelsVariantRecalibrator.tranches,
        snps_recalibration = if defined(SNPsVariantRecalibratorScattered.recalibration) then select_first([SNPsVariantRecalibratorScattered.recalibration])[idx] else select_first([SNPsVariantRecalibratorClassic.recalibration]),
        snps_recalibration_index = if defined(SNPsVariantRecalibratorScattered.recalibration_index) then select_first([SNPsVariantRecalibratorScattered.recalibration_index])[idx] else select_first([SNPsVariantRecalibratorClassic.recalibration_index]),
        snps_tranches = select_first([SNPGatherTranches.tranches, SNPsVariantRecalibratorClassic.tranches]),
        indel_filter_level = indel_filter_level,
        snp_filter_level = snp_filter_level,
        disk_size = medium_disk,
        docker = gatk_docker,
        gatk_path = gatk_path,
        max_retries = max_retries,
        preemptible_tries = preemptible_tries,
        runtime_zones = runtime_zones

    }

    # for large callsets we need to collect metrics from the shards and gather them later
    if (!is_small_callset) {
      call CollectVariantCallingMetrics as CollectMetricsSharded {
        input:
          input_vcf = ApplyRecalibration.recalibrated_vcf,
          input_vcf_index = ApplyRecalibration.recalibrated_vcf_index,
          metrics_filename_prefix = callset_name + "." + idx,
          dbsnp_vcf = dbsnp_vcf,
          dbsnp_vcf_index = dbsnp_vcf_index,
          interval_list = eval_interval_list,
          ref_dict = ref_dict,
          disk_size = medium_disk,
          docker = gatk_docker,
          gatk_path = gatk_path,
          max_retries = max_retries,
          preemptible_tries = preemptible_tries,
          runtime_zones = runtime_zones
      }
    }
  }

  # for small callsets we can gather the VCF shards and then collect metrics on it
  if (is_small_callset) {
    call GatherVcfs as FinalGatherVcf {
      input:
        input_vcfs_fofn = write_lines(ApplyRecalibration.recalibrated_vcf),
        output_vcf_name = callset_name + ".vcf.gz",
        disk_size = huge_disk,
        docker = gatk_docker,
        gatk_path = gatk_path,
        max_retries = max_retries,
        preemptible_tries = preemptible_tries,
        runtime_zones = runtime_zones
    }
    
    # Get only GP2 samples
    call Subset_vcf {
      input:
        input_vcf = FinalGatherVcf.output_vcf,
        input_vcf_index=FinalGatherVcf.output_vcf_index,
        output_vcf_name = callset_name + ".vcf.gz",
        ref_fasta = ref_fasta,
        ref_fasta_index = ref_fasta_index,
        ref_dict=ref_dict,
        sample_expression = sample_expression,
        disk_size = huge_disk,
        docker = gatk_docker,
        gatk_path = gatk_path,
        max_retries = max_retries,
        preemptible_tries = preemptible_tries,
        runtime_zones = runtime_zones
    }     

    call CollectVariantCallingMetrics as CollectMetricsOnFullVcf {
      input:
        input_vcf = Subset_vcf.output_vcf,
        input_vcf_index = Subset_vcf.output_vcf_index,
        metrics_filename_prefix = callset_name,
        dbsnp_vcf = dbsnp_vcf,
        dbsnp_vcf_index = dbsnp_vcf_index,
        interval_list = eval_interval_list,
        ref_dict = ref_dict,
        disk_size = large_disk,
        docker = gatk_docker,
        gatk_path = gatk_path,
        max_retries = max_retries,
        preemptible_tries = preemptible_tries,
        runtime_zones = runtime_zones
    }
  }

  # for large callsets we still need to gather the sharded metrics
  if (!is_small_callset) {
    call GatherMetrics {
      input:
        input_details_fofn = write_lines(select_all(CollectMetricsSharded.detail_metrics_file)),
        input_summaries_fofn = write_lines(select_all(CollectMetricsSharded.summary_metrics_file)),
        output_prefix = callset_name,
        disk_size = medium_disk,
        docker = gatk_docker,
        gatk_path = gatk_path,
        max_retries = max_retries,
        preemptible_tries = preemptible_tries,
        runtime_zones = runtime_zones
    }
    
    call Get_vcf_fofn {
      input:
        input_vcfs_fofn = write_lines(ApplyRecalibration.recalibrated_vcf),
        runtime_zones = runtime_zones
    }
  }

  output {
    # outputs from the small callset path through the wdl
    File? output_vcf = Subset_vcf.output_vcf
    File? output_vcf_index = Subset_vcf.output_vcf_index

    # select metrics from the small callset path and the large callset path
    File detail_metrics_file = select_first([CollectMetricsOnFullVcf.detail_metrics_file, GatherMetrics.detail_metrics_file])
    File summary_metrics_file = select_first([CollectMetricsOnFullVcf.summary_metrics_file, GatherMetrics.summary_metrics_file])

    # output of list of sharded vcfs from large callset path
    File? vcfs_fofn = Get_vcf_fofn.list_vcfs

    # output the interval list generated/used by this run workflow
    File output_intervals = DynamicallyCombineIntervals.output_intervals
  }
}

task GetNumberOfSamples {
  File sample_name_map
  String docker
  Int max_retries
  Int preemptible_tries
  String runtime_zones
  command <<<
    wc -l ${sample_name_map} | awk '{print $1}'
  >>>
  runtime {
    docker: docker
    memory: "1 GB"
    maxRetries: max_retries
    preemptible: preemptible_tries
    zones: runtime_zones
  }
  output {
    Int sample_count = read_int(stdout())
  }
}

task ImportGVCFs {
  String user_project_id
  File sample_name_map
  String interval

  String workspace_dir_name

  String gatk_path
  String docker
  String runtime_zones
  Int disk_size
  Int max_retries
  Int preemptible_tries
  
  Int batch_size

  command <<<
    set -e

    rm -rf ${workspace_dir_name}

    # The memory setting here is very important and must be several GB lower
    # than the total memory allocated to the VM because this tool uses
    # a significant amount of non-heap memory for native libraries.
    # Also, testing has shown that the multithreaded reader initialization
    # does not scale well beyond 5 threads, so don't increase beyond that.
    ${gatk_path} --java-options "-Xmx4g -Xms4g" \
    GenomicsDBImport \
    --gcs-project-for-requester-pays "${user_project_id}" \
    --genomicsdb-workspace-path ${workspace_dir_name} \
    --batch-size ${batch_size} \
    -L ${interval} \
    --sample-name-map ${sample_name_map} \
    --reader-threads 5 \
    -ip 500

    tar -cf ${workspace_dir_name}.tar ${workspace_dir_name}

  >>>
  runtime {
    docker: docker
    memory: "7 GB"
    cpu: "2"
    disks: "local-disk " + disk_size + " HDD"
    maxRetries: max_retries
    preemptible: preemptible_tries
    zones: runtime_zones
  }
  output {
    File output_genomicsdb = "${workspace_dir_name}.tar"
  }
}

task GenotypeGVCFs {
  File workspace_tar
  String interval

  String output_vcf_filename

  String gatk_path

  File ref_fasta
  File ref_fasta_index
  File ref_dict

  String dbsnp_vcf
  String docker
  String runtime_zones
  Int disk_size
  Int max_retries
  Int preemptible_tries

  # This is needed for gVCFs generated with GATK3 HaplotypeCaller
  Boolean allow_old_rms_mapping_quality_annotation_data = false
  
  command <<<
    set -e

    tar -xf ${workspace_tar}
    WORKSPACE=$( basename ${workspace_tar} .tar)

    ${gatk_path} --java-options "-Xmx8g -Xms7g" \
     GenotypeGVCFs \
     -R ${ref_fasta} \
     -O ${output_vcf_filename} \
     -D ${dbsnp_vcf} \
     -G StandardAnnotation \
     --only-output-calls-starting-in-intervals \
     --use-new-qual-calculator \
     -V gendb://$WORKSPACE \
     -L ${interval}
     
  >>>
  runtime {
    docker: docker
    # for a small number of shards 7.5 GB (n1-standard-2) was not enough, so we're increasing to 13 GB (n1-highmem-2)
    memory: "13 GB"
    cpu: "2"
    disks: "local-disk " + disk_size + " HDD"
    maxRetries: max_retries
    preemptible: preemptible_tries
    zones: runtime_zones
  }
  output {
    File output_vcf = "${output_vcf_filename}"
    File output_vcf_index = "${output_vcf_filename}.tbi"
  }
}

task HardFilterAndMakeSitesOnlyVcf {
  File vcf
  File vcf_index
  Float excess_het_threshold

  String variant_filtered_vcf_filename
  String sites_only_vcf_filename
  String gatk_path

  String docker
  String runtime_zones
  Int disk_size
  Int max_retries
  Int preemptible_tries

  command {
    set -e

    ${gatk_path} --java-options "-Xmx3g -Xms3g" \
      VariantFiltration \
      --filter-expression "ExcessHet > ${excess_het_threshold}" \
      --filter-name ExcessHet \
      -O ${variant_filtered_vcf_filename} \
      -V ${vcf}

    ${gatk_path} --java-options "-Xmx3g -Xms3g" \
      MakeSitesOnlyVcf \
      --INPUT ${variant_filtered_vcf_filename} \
      --OUTPUT ${sites_only_vcf_filename}

  }
  runtime {
    docker: docker
    memory: "3.5 GB"
    cpu: "1"
    disks: "local-disk " + disk_size + " HDD"
    maxRetries: max_retries
    preemptible: preemptible_tries
    zones: runtime_zones
  }
  output {
    File variant_filtered_vcf = "${variant_filtered_vcf_filename}"
    File variant_filtered_vcf_index = "${variant_filtered_vcf_filename}.tbi"
    File sites_only_vcf = "${sites_only_vcf_filename}"
    File sites_only_vcf_index = "${sites_only_vcf_filename}.tbi"
  }
}

task IndelsVariantRecalibrator {
  String recalibration_filename
  String tranches_filename

  Array[String] recalibration_tranche_values
  Array[String] recalibration_annotation_values

  File sites_only_variant_filtered_vcf
  File sites_only_variant_filtered_vcf_index

  File mills_resource_vcf
  File axiomPoly_resource_vcf
  File dbsnp_resource_vcf
  File mills_resource_vcf_index
  File axiomPoly_resource_vcf_index
  File dbsnp_resource_vcf_index

  String gatk_path
  String docker
  String runtime_zones
  Int disk_size
  Int max_retries
  Int preemptible_tries

  command {
    ${gatk_path} --java-options "-Xmx24g -Xms24g" \
      VariantRecalibrator \
      -V ${sites_only_variant_filtered_vcf} \
      -O ${recalibration_filename} \
      --tranches-file ${tranches_filename} \
      --trust-all-polymorphic \
      -tranche ${sep=' -tranche ' recalibration_tranche_values} \
      -an ${sep=' -an ' recalibration_annotation_values} \
      -mode INDEL \
      --max-gaussians 4 \
      --resource:mills,known=false,training=true,truth=true,prior=12 ${mills_resource_vcf} \
      --resource:axiomPoly,known=false,training=true,truth=false,prior=10 ${axiomPoly_resource_vcf} \
      --resource:dbsnp,known=true,training=false,truth=false,prior=2 ${dbsnp_resource_vcf}
  }
  runtime {
    docker: docker
    memory: "26 GB"
    cpu: "2"
    disks: "local-disk " + disk_size + " HDD"
    maxRetries: max_retries
    preemptible: preemptible_tries
    zones: runtime_zones
  }
  output {
    File recalibration = "${recalibration_filename}"
    File recalibration_index = "${recalibration_filename}.idx"
    File tranches = "${tranches_filename}"
  }
}

task SNPsVariantRecalibratorCreateModel {
  String recalibration_filename
  String tranches_filename
  Int downsampleFactor
  String model_report_filename

  Array[String] recalibration_tranche_values
  Array[String] recalibration_annotation_values

  File sites_only_variant_filtered_vcf
  File sites_only_variant_filtered_vcf_index

  File hapmap_resource_vcf
  File omni_resource_vcf
  File one_thousand_genomes_resource_vcf
  File dbsnp_resource_vcf
  File hapmap_resource_vcf_index
  File omni_resource_vcf_index
  File one_thousand_genomes_resource_vcf_index
  File dbsnp_resource_vcf_index

  String gatk_path
  String docker
  String runtime_zones
  Int disk_size
  Int max_retries
  Int preemptible_tries

  command {
    ${gatk_path} --java-options "-Xmx100g -Xms100g" \
      VariantRecalibrator \
      -V ${sites_only_variant_filtered_vcf} \
      -O ${recalibration_filename} \
      --tranches-file ${tranches_filename} \
      --trust-all-polymorphic \
      -tranche ${sep=' -tranche ' recalibration_tranche_values} \
      -an ${sep=' -an ' recalibration_annotation_values} \
      -mode SNP \
      --sample-every-Nth-variant ${downsampleFactor} \
      --output-model ${model_report_filename} \
      --max-gaussians 6 \
      --resource:hapmap,known=false,training=true,truth=true,prior=15 ${hapmap_resource_vcf} \
      --resource:omni,known=false,training=true,truth=true,prior=12 ${omni_resource_vcf} \
      --resource:1000G,known=false,training=true,truth=false,prior=10 ${one_thousand_genomes_resource_vcf} \
      --resource:dbsnp,known=true,training=false,truth=false,prior=7 ${dbsnp_resource_vcf}
  }
  runtime {
    docker: docker
    memory: "104 GB"
    cpu: "2"
    disks: "local-disk " + disk_size + " HDD"
    maxRetries: max_retries
    preemptible: preemptible_tries
    zones: runtime_zones
  }
  output {
    File model_report = "${model_report_filename}"
  }
}

task SNPsVariantRecalibrator {
  String recalibration_filename
  String tranches_filename
  File? model_report

  Array[String] recalibration_tranche_values
  Array[String] recalibration_annotation_values

  File sites_only_variant_filtered_vcf
  File sites_only_variant_filtered_vcf_index

  File hapmap_resource_vcf
  File omni_resource_vcf
  File one_thousand_genomes_resource_vcf
  File dbsnp_resource_vcf
  File hapmap_resource_vcf_index
  File omni_resource_vcf_index
  File one_thousand_genomes_resource_vcf_index
  File dbsnp_resource_vcf_index

  String gatk_path
  String docker
  String runtime_zones
  Int? machine_mem_gb
  Int auto_mem = ceil(2*size(sites_only_variant_filtered_vcf, "GB" ))
  Int machine_mem = select_first([machine_mem_gb, if auto_mem < 7 then 7 else auto_mem])
  Int disk_size
  Int max_retries
  Int preemptible_tries

  command {
    # mbookman: For runs of around 4,000 samples, the 3g default memory
    # was nowhere near sufficient. With higher values, like 32g, this
    # step finished reliably and much more quickly (under 4 hrs).

    # dvismer: For runs of <how many samples?>, we increased to 100g
    # and this step finished in <approximate time?>
    ${gatk_path} --java-options "-Xmx100g -Xms100g" \
      VariantRecalibrator \
      -V ${sites_only_variant_filtered_vcf} \
      -O ${recalibration_filename} \
      --tranches-file ${tranches_filename} \
      --trust-all-polymorphic \
      -tranche ${sep=' -tranche ' recalibration_tranche_values} \
      -an ${sep=' -an ' recalibration_annotation_values} \
      -mode SNP \
      ${"--input-model " + model_report + " --output-tranches-for-scatter "} \
      --max-gaussians 6 \
      --resource:hapmap,known=false,training=true,truth=true,prior=15 ${hapmap_resource_vcf} \
      --resource:omni,known=false,training=true,truth=true,prior=12 ${omni_resource_vcf} \
      --resource:1000G,known=false,training=true,truth=false,prior=10 ${one_thousand_genomes_resource_vcf} \
      --resource:dbsnp,known=true,training=false,truth=false,prior=7 ${dbsnp_resource_vcf}
  }
  runtime {
    docker: docker
    memory: "104 GiB"
    disks: "local-disk " + disk_size + " HDD"
    maxRetries: max_retries
    preemptible: preemptible_tries
    zones: runtime_zones
  }
  output {
    File recalibration = "${recalibration_filename}"
    File recalibration_index = "${recalibration_filename}.idx"
    File tranches = "${tranches_filename}"
  }
}

task GatherTranches {
  File input_fofn
  String output_filename

  String gatk_path

  String docker
  String? runtime_zones
  Int disk_size
  Int max_retries
  Int preemptible_tries

  command <<<
    set -e
    set -o pipefail

    # this is here to deal with the JES bug where commands may be run twice
    rm -rf tranches

    mkdir tranches
    RETRY_LIMIT=5

    count=0
    # mbookman: correct the path to gsutil
    # https://github.com/gatk-workflows/gatk4-germline-snps-indels/issues/41
    until cat ${input_fofn} | gsutil -m cp -L cp.log -c -I tranches/; do
        sleep 1
        ((count++)) && ((count >= $RETRY_LIMIT)) && break
    done
    if [ "$count" -ge "$RETRY_LIMIT" ]; then
        echo 'Could not copy all the tranches from the cloud' && exit 1
    fi

    cat ${input_fofn} | rev | cut -d '/' -f 1 | rev | awk '{print "tranches/" $1}' > inputs.list

      ${gatk_path} --java-options "-Xmx6g -Xms6g" \
      GatherTranches \
      --input inputs.list \
      --output ${output_filename}
  >>>
  runtime {
    docker: docker
    memory: "7 GB"
    cpu: "2"
    disks: "local-disk " + disk_size + " HDD"
    maxRetries: max_retries
    preemptible: preemptible_tries
    zones: runtime_zones
  }
  output {
    File tranches = "${output_filename}"
  }
}

task ApplyRecalibration {
  String recalibrated_vcf_filename
  File input_vcf
  File input_vcf_index
  File indels_recalibration
  File indels_recalibration_index
  File indels_tranches
  File snps_recalibration
  File snps_recalibration_index
  File snps_tranches

  Float indel_filter_level
  Float snp_filter_level

  String gatk_path
  String docker
  String runtime_zones
  Int disk_size
  Int max_retries
  Int preemptible_tries

  command {
    set -e

    ${gatk_path} --java-options "-Xmx5g -Xms5g" \
      ApplyVQSR \
      -O tmp.indel.recalibrated.vcf \
      -V ${input_vcf} \
      --recal-file ${indels_recalibration} \
      --tranches-file ${indels_tranches} \
      --truth-sensitivity-filter-level ${indel_filter_level} \
      --create-output-variant-index true \
      -mode INDEL

    ${gatk_path} --java-options "-Xmx5g -Xms5g" \
      ApplyVQSR \
      -O ${recalibrated_vcf_filename} \
      -V tmp.indel.recalibrated.vcf \
      --recal-file ${snps_recalibration} \
      --tranches-file ${snps_tranches} \
      --truth-sensitivity-filter-level ${snp_filter_level} \
      --create-output-variant-index true \
      -mode SNP
  }
  runtime {
    docker: docker
    memory: "7 GB"
    cpu: "1"
    zones: runtime_zones
    disks: "local-disk " + disk_size + " HDD"
    maxRetries: max_retries
    preemptible: preemptible_tries
  }
  output {
    File recalibrated_vcf = "${recalibrated_vcf_filename}"
    File recalibrated_vcf_index = "${recalibrated_vcf_filename}.tbi"
  }
}

task GatherVcfs {
  File input_vcfs_fofn
  String output_vcf_name
  String gatk_path

  String docker
  String runtime_zones
  Int disk_size
  Int max_retries
  Int preemptible_tries

  command <<<
    set -e

    # Now using NIO to localize the vcfs but the input file must have a ".list" extension
    mv ${input_vcfs_fofn} inputs.list

    # --ignore-safety-checks makes a big performance difference so we include it in our invocation.
    # This argument disables expensive checks that the file headers contain the same set of
    # genotyped samples and that files are in order by position of first record.
    ${gatk_path} --java-options "-Xmx6g -Xms6g" \
    GatherVcfsCloud \
    --ignore-safety-checks \
    --gather-type BLOCK \
    --input inputs.list \
    --output ${output_vcf_name}

    ${gatk_path} --java-options "-Xmx6g -Xms6g" \
    IndexFeatureFile \
    -I ${output_vcf_name}
  >>>
  runtime {
    docker: docker
    memory: "7 GB"
    cpu: "1"
    disks: "local-disk " + disk_size + " HDD"
    maxRetries: max_retries
    preemptible: preemptible_tries
    zones: runtime_zones
  }
  output {
    File output_vcf = "${output_vcf_name}"
    File output_vcf_index = "${output_vcf_name}.tbi"
  }
}

task Subset_vcf {
  File ref_fasta
  File ref_fasta_index
  File ref_dict

  File input_vcf
  File input_vcf_index
  String output_vcf_name
  String sample_expression
  
  String gatk_path
  String docker
  String runtime_zones
  Int disk_size
  Int max_retries
  Int preemptible_tries

  command {
    ${gatk_path} --java-options "-Xmx6g -Xms6g" \
        SelectVariants \
        -R ${ref_fasta} \
        -V ${input_vcf} \
        -se ${sample_expression} \
        -O ${output_vcf_name}
  }
  output {
    File output_vcf = "${output_vcf_name}"
    File output_vcf_index = "${output_vcf_name}.tbi"
  }
  runtime {
    docker: docker
    memory: "7 GB"
    cpu: 2
    disks: "local-disk " + disk_size + " HDD"
    maxRetries: max_retries
    preemptible: preemptible_tries
    zones: runtime_zones
  }
}


task CollectVariantCallingMetrics {
  File input_vcf
  File input_vcf_index

  String metrics_filename_prefix
  File dbsnp_vcf
  File dbsnp_vcf_index
  File interval_list
  File ref_dict

  String gatk_path
  String docker
  String runtime_zones
  Int disk_size
  Int max_retries
  Int preemptible_tries

  command {
    ${gatk_path} --java-options "-Xmx6g -Xms6g" \
      CollectVariantCallingMetrics \
      --INPUT ${input_vcf} \
      --DBSNP ${dbsnp_vcf} \
      --SEQUENCE_DICTIONARY ${ref_dict} \
      --OUTPUT ${metrics_filename_prefix} \
      --THREAD_COUNT 8 \
      --TARGET_INTERVALS ${interval_list}
  }
  output {
    File detail_metrics_file = "${metrics_filename_prefix}.variant_calling_detail_metrics"
    File summary_metrics_file = "${metrics_filename_prefix}.variant_calling_summary_metrics"
  }
  runtime {
    docker: docker
    memory: "7 GB"
    cpu: 2
    disks: "local-disk " + disk_size + " HDD"
    maxRetries: max_retries
    preemptible: preemptible_tries
    zones: runtime_zones
  }
}

task GatherMetrics {
  File input_details_fofn
  File input_summaries_fofn

  String output_prefix

  String gatk_path
  String docker
  String runtime_zones
  Int disk_size
  Int max_retries
  Int preemptible_tries

  command <<<
    set -e
    set -o pipefail

    # this is here to deal with the JES bug where commands may be run twice
    rm -rf metrics

    mkdir metrics
    RETRY_LIMIT=5

    count=0
    # mbookman: correct the path to gsutil
    # https://github.com/gatk-workflows/gatk4-germline-snps-indels/issues/41
    until cat ${input_details_fofn} | gsutil -m cp -L cp.log -c -I metrics/; do
        sleep 1
        ((count++)) && ((count >= $RETRY_LIMIT)) && break
    done
    if [ "$count" -ge "$RETRY_LIMIT" ]; then
        echo 'Could not copy all the metrics from the cloud' && exit 1
    fi

    count=0
    # mbookman: correct the path to gsutil
    # https://github.com/gatk-workflows/gatk4-germline-snps-indels/issues/41
    until cat ${input_summaries_fofn} | gsutil -m cp -L cp.log -c -I metrics/; do
        sleep 1
        ((count++)) && ((count >= $RETRY_LIMIT)) && break
    done
    if [ "$count" -ge "$RETRY_LIMIT" ]; then
        echo 'Could not copy all the metrics from the cloud' && exit 1
    fi

    INPUT=$(cat ${input_details_fofn} | rev | cut -d '/' -f 1 | rev | sed s/.variant_calling_detail_metrics//g | awk '{printf("--INPUT metrics/%s ", $1)}')

    ${gatk_path} --java-options "-Xmx2g -Xms2g" \
    AccumulateVariantCallingMetrics \
    $INPUT \
    -O ${output_prefix}
  >>>
  runtime {
    docker: docker
    memory: "3 GB"
    cpu: "1"
    disks: "local-disk " + disk_size + " HDD"
    maxRetries: max_retries
    preemptible: preemptible_tries
    zones: runtime_zones
  }
  output {
    File detail_metrics_file = "${output_prefix}.variant_calling_detail_metrics"
    File summary_metrics_file = "${output_prefix}.variant_calling_summary_metrics"
  }
}

task DynamicallyCombineIntervals {
  File intervals
  Int merge_count
  Int max_retries
  Int preemptible_tries
  String runtime_zones
  
  command {
    python << CODE
    def parse_interval(interval):
        colon_split = interval.split(":")
        chromosome = colon_split[0]
        dash_split = colon_split[1].split("-")
        start = int(dash_split[0])
        end = int(dash_split[1])
        return chromosome, start, end

    def add_interval(chr, start, end):
        lines_to_write.append(chr + ":" + str(start) + "-" + str(end))
        return chr, start, end

    count = 0
    chain_count = ${merge_count}
    l_chr, l_start, l_end = "", 0, 0
    lines_to_write = []
    with open("${intervals}") as f:
        with open("out.intervals", "w") as f1:
            for line in f.readlines():
                # initialization
                if count == 0:
                    w_chr, w_start, w_end = parse_interval(line)
                    count = 1
                    continue
                # reached number to combine, so spit out and start over
                if count == chain_count:
                    l_char, l_start, l_end = add_interval(w_chr, w_start, w_end)
                    w_chr, w_start, w_end = parse_interval(line)
                    count = 1
                    continue

                c_chr, c_start, c_end = parse_interval(line)
                # if adjacent keep the chain going
                if c_chr == w_chr and c_start == w_end + 1:
                    w_end = c_end
                    count += 1
                    continue
                # not adjacent, end here and start a new chain
                else:
                    l_char, l_start, l_end = add_interval(w_chr, w_start, w_end)
                    w_chr, w_start, w_end = parse_interval(line)
                    count = 1
            if l_char != w_chr or l_start != w_start or l_end != w_end:
                add_interval(w_chr, w_start, w_end)
            f1.writelines("\n".join(lines_to_write))
    CODE
  }

  runtime {
    memory: "3 GB"
    maxRetries: max_retries
    preemptible: preemptible_tries
    docker: "python:2.7"
    zones: runtime_zones
  }

  output {
    File output_intervals = "out.intervals"
  }
}

task Get_vcf_fofn {
  File input_vcfs_fofn
  String runtime_zones
  String output_file_name = "vcf_shards.list"

command <<<
    set -e
    set -o pipefail
      
    mv ${input_vcfs_fofn} ${output_file_name}

  >>>
  runtime {
    docker: "ubuntu:20.04"
    memory: "3.75 GB"
    cpu: "1"
    zones: runtime_zones
  }
  output {
    File list_vcfs = "${output_file_name}"
  }
}