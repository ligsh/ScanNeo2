rule download_vep_plugins:
    output:
        directory("resources/vep/plugins"),
    log:
        "logs/download/vep_plugins.log",
    conda:
        "../envs/basic.yml"
    params:
        release=f"""{config['reference']['release']}""",
        base_url=lambda w: config.get("resources", {}).get("base_url", "").rstrip("/"),
    message:
        "Downloading VEP plugins"
    shell:
        """
        (
            mkdir -p resources/vep/plugins/
            if [ -n "{params.base_url}" ]; then
              _b="{params.base_url}/vep/plugins"
              bash workflow/scripts/fetch_resource.sh "$_b/NMD.pm"     {output}/NMD.pm
              bash workflow/scripts/fetch_resource.sh "$_b/Downstream.pm" {output}/Downstream.pm
              bash workflow/scripts/fetch_resource.sh "$_b/Wildtype.pm"   {output}/Wildtype.pm
            else
              curl --fail -L --retry 5 --retry-all-errors -o {output}/NMD.pm     https://raw.githubusercontent.com/Ensembl/VEP_plugins/release/{params.release}/NMD.pm
              curl --fail -L --retry 5 --retry-all-errors -o {output}/Downstream.pm https://raw.githubusercontent.com/Ensembl/VEP_plugins/release/{params.release}/Downstream.pm
              curl --fail -L --retry 5 --retry-all-errors -o {output}/Wildtype.pm https://raw.githubusercontent.com/griffithlab/pVAC-Seq/master/pvacseq/VEP_plugins/Wildtype.pm
            fi
        ) >{log} 2>&1
        """


rule download_vep_cache:
    output:
        directory("resources/vep/cache"),
    log:
        "logs/download/vep_cache.log",
    conda:
        "../envs/basic.yml"
    params:
        release=f"""{config['reference']['release']}""",
        base_url=lambda w: config.get("resources", {}).get("base_url", "").rstrip("/"),
    message:
        "Downloading VEP cache"
    shell:
        """
        (
            mkdir -p {output}
            if [ -n "{params.base_url}" ]; then
              _u="{params.base_url}/vep/cache/homo_sapiens_vep_{params.release}_GRCh38.tar.gz"
            else
              _u="https://ftp.ensembl.org/pub/release-{params.release}/variation/indexed_vep_cache/homo_sapiens_vep_{params.release}_GRCh38.tar.gz"
            fi
            bash workflow/scripts/fetch_resource.sh \
                "$_u" \
                resources/vep/cache/homo_sapiens_vep_{params.release}_GRCh38.tar.gz

            tar -xzf resources/vep/cache/homo_sapiens_vep_{params.release}_GRCh38.tar.gz -C resources/vep/cache/
            rm resources/vep/cache/homo_sapiens_vep_{params.release}_GRCh38.tar.gz
        ) >{log} 2>&1
        """


#      curl -L https://ftp.ensembl.org/pub/release-110/variation/indexed_vep_cache/homo_sapiens_vep_110_GRCh38.tar.gz \
# https://g-a8b222.dd271.03c0.data.globus.org/ensemblorg/pub/release-{params.release}/variation/indexed_vep_cache/homo_sapiens_vep_{params.release}_GRCh38.tar.gz


rule index_variants:
    input:
        "results/{sample}/variants/{vartype}.vcf.gz",
    output:
        "results/{sample}/variants/{vartype}.vcf.gz.tbi",
    log:
        "logs/{sample}/annotation/index_variants_{vartype}.log",
    conda:
        "../envs/samtools.yml"
    shell:
        """
        tabix {input} >{log} 2>&1
        """


rule annotate_variants:
    input:
        calls="results/{sample}/variants/{vartype}.vcf.gz",
        idx="results/{sample}/variants/{vartype}.vcf.gz.tbi",
        fasta="resources/refs/genome.fasta",
        cache="resources/vep/cache",
        plugins="resources/vep/plugins",
    output:
        calls="results/{sample}/annotation/{vartype}.vcf",
        stats="results/{sample}/annotation/{vartype}.html",
    log:
        "logs/{sample}/annotation/annotate_variants_{vartype}.log",
    # the vep wrapper forwards threads to --fork; VEP --everything is slow and
    # scales well across forks (it was the critical-path tail of the TESLA run)
    threads: 16
    params:
        plugins=["NMD", "Wildtype", "Downstream"],
        extra="--everything",  # optional: extra arguments
    wrapper:
        "v5.9.0/bio/vep/annotate"
