rule FastqToBam:
    input:
        R1=DIR_trimmed_fastq + "/{wildcard}_R1.fastq",
        R2=DIR_trimmed_fastq + "/{wildcard}_R2.fastq",
    output:
        DIR_bams + "/uBAM/{wildcard}.bam",
    params:
        sample="{wildcard}",
    run:
        shell(
            "fgbio FastqToBam -Xmx20G \
        --input {input.R1} {input.R2} \
        --output {output} \
        --read-structure 3M2S+T 3M2S+T \
        --umi-tag RX \
        --sample {params.sample} \
        --library lib1 \
        --platform illumina \
        --sort true"
        )


# Go back to the Fastq format
rule BamtoFastq:
    input:
        DIR_bams + "/uBAM/{wildcard}.bam",
    params:
        PATH_hg38=PATH_hg38,
    output:
        temp(DIR_fastq + "/consensus_fq/{wildcard}.fastq"),
    threads: 12
    run:
        shell(
            "picard SamToFastq -Xmx20G I={input} F={output} INCLUDE_NON_PF_READS=true INCLUDE_NON_PRIMARY_ALIGNMENTS=true INTERLEAVE=true"
        )


# Generate mapped bam
rule mapBAM:
    input:
        DIR_fastq + "/consensus_fq/{wildcard}.fastq",
    params:
        PATH_hg38=PATH_hg38,
    output:
        temp(DIR_bams + "/mBAM_raw/{wildcard}.bam"),
    threads: 12 # keep the same for deterministic
    run:
        shell("bwa mem {params.PATH_hg38} {input} -p -Y -t {threads} > {output}")

rule MergeBamAlignment:
    input:
        mBAM=DIR_bams + "/readGroup/{wildcard}.bam",
        uBAM=DIR_bams + "/uBAM/{wildcard}.bam",
    params:
        PATH_hg38=PATH_hg38,
    output:
        DIR_bams + "/mBAM/{wildcard}.bam",
    threads: 12
    run:
        shell(
            "picard MergeBamAlignment -Xmx20G UNMAPPED={input.uBAM} ALIGNED={input.mBAM} O={output} R={params.PATH_hg38} \
            CLIP_OVERLAPPING_READS=false \
            CLIP_ADAPTERS=false \
            INCLUDE_SECONDARY_ALIGNMENTS=true \
            ALIGNER_PROPER_PAIR_FLAGS=true \
            EXPECTED_ORIENTATIONS=FR \
            MAX_INSERTIONS_OR_DELETIONS=-1 \
            VALIDATION_STRINGENCY=SILENT \
            CREATE_INDEX=true"
        )

# Add read groups to the mapped bam file
rule addRG:
    input:
        DIR_bams + "/mBAM_raw/{wildcard}.bam",
    params:
        PATH_hg38=PATH_hg38,
        sample="{wildcard}",
    output:
        temp(DIR_bams + "/readGroup/{wildcard}.bam"),
    threads: 12
    run:
        shell(
            "picard AddOrReplaceReadGroups -Xmx20G I={input} O={output} RGID=A RGSM={params.sample} RGPL=illumina RGLB=lib1 RGPU=unit1 SORT_ORDER=queryname"
        )



rule indel_realignment:
    input:
        MAPPED_bam=DIR_bams + "/mBAM/{wildcard}.bam",
        PATH_bed=PATH_bed,
        PATH_hg38=PATH_hg38,
    params:
        min_mapping_quality=20,
    output:
        DIR_bams + "/abra2/{wildcard}.bam",
    threads: 12
    run:
        shell(
            "java -Xms64G -jar /home/amunzur/anaconda3/envs/snakemake/share/abra2-2.24-1/abra2.jar \
        --in {input.MAPPED_bam} \
        --out {output} \
        --ref {input.PATH_hg38} \
        --threads {threads} --index \
        --nosort \
        --no-edge-ci \
        --mad 20000 \
        --cons \
        --sa \
        --cl 0 \
        --targets {input.PATH_bed} \
        --tmpdir /groups/wyattgrp/users/amunzur/COMPOST_BIN > \
        '/groups/wyattgrp/users/amunzur/pipeline/results/logs_slurm/indel_realignment/{wildcards.wildcard}'"
        )

rule fixmate:
    input:
        DIR_bams + "/abra2/{wildcard}.bam",
    output:
        temp(DIR_bams + "/fixmate/{wildcard}.bam"),
    threads: 12
    run:
        shell(
            "picard -Xmx40g FixMateInformation I={input} O={output} SORT_ORDER=coordinate"
        )

rule subset_to_proper_pairs:
    input:
        DIR_bams + "/fixmate/{wildcard}.bam"
    output:
        temp(DIR_bams + "/fixmate_proper_pair/{wildcard}.bam"),
    threads: 12
    run:
        shell(
            "sambamba view {input} -F 'proper_pair' -t 12 -f bam -l 0 -o {output}"
        )

rule sort_subseted_to_proper_pairs:
    input:
        DIR_bams + "/fixmate_proper_pair/{wildcard}.bam"
    output:
        temp(DIR_bams + "/fixmate_proper_pair_sorted/{wildcard}.bam"),
    threads: 12
    run:
        shell(
            "samtools sort {input} -o {output}"
        )

rule recalibrate_bases:
    input:
        DIR_bams + "/fixmate_proper_pair_sorted/{wildcard}.bam",
    output:
        DIR_recalibrated_base_scores + "/{wildcard}_table",
    params:
        PATH_hg38=PATH_hg38,
        PATH_known_indels=PATH_known_indels,
        PATH_gold_std_indels=PATH_gold_std_indels,
        PATH_SNP_db=PATH_SNP_db,
    threads: 12
    run:
        shell(
            "~/gatk-4.2.0.0/gatk BaseRecalibrator -I {input} -R {params.PATH_hg38} --known-sites {params.PATH_known_indels} --known-sites {params.PATH_gold_std_indels} --known-sites {params.PATH_SNP_db} -O {output}"
        )


rule apply_base_scores:
    input:
        fixmate_BAM=DIR_bams + "/fixmate/{wildcard}.bam",
        base_scores=DIR_recalibrated_base_scores + "/{wildcard}_table",
    output:
        uncollapsed_BAM=DIR_bams + "/uncollapsed_BAM/{wildcard}.bam",
    threads: 12
    run:
        shell(
            "~/gatk-4.2.0.0/gatk ApplyBQSR --input {input.fixmate_BAM} --output {output.uncollapsed_BAM} --bqsr-recal-file {input.base_scores}"
        )


# Identify reads or read pairs that originate from the same source molecule based on genomic positions and UMI
rule GroupReadsByUmi:
    input:
        DIR_bams + "/uncollapsed_BAM/{wildcard}.bam",  # output of the fixmate_and_recalibrate_bases rule from the process_bams.smk file
    output:
        temp(DIR_bams + "/grouped_umi_BAM/{wildcard}.bam"),
    params:
        PATH_hg38=PATH_hg38,
    run:
        shell(
            "fgbio GroupReadsByUmi -Xmx20G --input={input} --output={output} --strategy=paired --edits=1 --min-map-q=20"
        )

rule CallMolecularConsensusReads:
    input:
        DIR_bams + "/grouped_umi_BAM/{wildcard}.bam",  # output of the fixmate_and_recalibrate_bases rule from the process_bams.smk file
    output:
        DIR_bams + "/SSCS_uBAM/{wildcard}.bam",
    threads: 12
    params:
        min_reads=2,
        min_input_base_quality=20,
        error_rate_post_umi=40,
        error_rate_pre_umi=45,
    run:
        shell(
            "fgbio CallMolecularConsensusReads -Xmx20G --input={input} --output={output} --threads={threads} \
            --read-name-prefix=singlex \
            --sort-order=Queryname \
            --consensus-call-overlapping-bases=true \
            --error-rate-pre-umi={params.error_rate_pre_umi} \
            --error-rate-post-umi={params.error_rate_post_umi} \
            --min-input-base-quality={params.min_input_base_quality} \
            --min-reads={params.min_reads}"
        )