
module ModelEvaluation
    using Flux, Statistics, Graphs, GNNGraphs, Clustering, Distances, LinearAlgebra, Leiden
    using ..Types

    function cluster_conductance(graph::GNNGraph, labels::Vector{Int}, k::Real)
        nodes = findall(node -> node == k, labels) |>
                Set
        neighbour_list = neighbors.(Ref(graph), nodes)

        internal = mapreduce(
            neighbours -> count(node -> node in nodes, neighbours),
            +,
            neighbour_list
        )
        boundary = mapreduce(
            neighbours -> count(node -> node ∉ nodes, neighbours),
            +,
            neighbour_list
        )

        volume = internal + boundary

        return volume == 0 ? 0 : boundary / (volume)
    end

    const AcceptedMetrics = Union{[
            SqEuclidean,
            Euclidean,
            CosineDist,
            CorrDist,
            Cityblock,
            Chebyshev
        ]...
    }


    # how similar is a node to its own community, compared
    # to other communities?
    # this function takes GNN node embeddings, and
    # a vector of assignments (e.g. from kmeans or leiden)
    # Scores range from -1 to 1
    export embedding_metrics
    function embedding_metrics(
        graph::GNNGraph,
        embeddings::Matrix{<:Real},
        labels::Vector{<:Real},
        metric::AcceptedMetrics = SqEuclidean()
    )
        dist_mtx = pairwise(metric, embeddings, embeddings)
        metrics = Dict(
            :silhouettes => clustering_quality(labels, dist_mtx; quality_index=:silhouettes),
            :modularity => modularity(graph, labels),
            :conductance => cluster_conductance.(Ref(graph), Ref(labels), unique(labels)) |> mean,
        )
        return metrics
    end

    export evaluate_embeddings
    function evaluate_embeddings(
        embeddings,
        graph;
        k = Int64(round(sqrt(size(embeddings, 2))))
    )
        norm_embeddings = Flux.normalise(embeddings; dims = 1)
        knn = knn_graph(norm_embeddings, k)
        clusters = leiden(adjacency_matrix(knn), "ngrb")
        return embedding_metrics(graph, norm_embeddings, clusters)
    end

    export fast_evaluate_embeddings
    function fast_evaluate_embeddings(embeddings, graph; k = Int64(round(sqrt(size(embeddings, 2)))))
        norm_embeddings = Flux.normalise(embeddings; dims = 1)
        clusters = kmeans(norm_embeddings, k)
        return embedding_metrics(graph, norm_embeddings, clusters.assignments)
    end

    # todo, examine GPU compat
    # Number of nodes in the same cluster compared to the total number
    # of nodes
    # We'd expect negative views to have lower cluster rate
    export intra_cluster_rate
    function intra_cluster_rate(assignments::Vector{<:Real}, graph)
        pos_intra = 0
        pos_total = 0
        neg_intra = 0
        neg_total = 0
        edge_weights = get_edge_weight(graph)

            for (i, e) in enumerate(edges(graph))
                source, target = src(e), dst(e)
                weight = edge_weights[i]

                if weight > 0
                    pos_total += 1
                    if assignments[source] == assignments[target]
                        pos_intra += 1
                    end
                elseif weight < 0
                    neg_total += 1
                    if assignments[source] == assignments[target]
                        neg_intra += 1
                    end
                end
            end

            if (neg_total > 0)
                return Dict(
                    :positive_intra => pos_intra / max(pos_total, 1),
                    :negative_intra => neg_intra / max(neg_total, 1)
                )
            else
                return Dict(
                    :intra => pos_intra / max(pos_total, 1)
                )
            end
    end

    function intra_cluster_rate(assignments::Vector{<:Real}, views::Array, names::Vector{String})
        if names == Nothing
            return [intra_cluster_rate(assignments, v.graph) for v in views]
        else
             return Dict(name => intra_cluster_rate(assignments, v.graph) for (v, name) in zip(views, names))
        end
    end

    export model_summary
    function model_summary(
        embeddings::Matrix{<:Real},
        assignments::Vector{<:Real},
        composite_graph::GNNGraph,
        views::Vector,
        model_params::NamedTuple,
        names::Union{Nothing, Vector{String}} = nothing,
    )
        composite_rates = intra_cluster_rate(assignments, composite_graph)
        intra_rates = intra_cluster_rate(assignments, views, names)
        embed_eval = fast_evaluate_embeddings(embeddings, composite_graph)

        # baseline comparison
        base_adj_mat = adjacency_matrix(composite_graph)
        base_clusters = leiden(base_adj_mat, "ngrb")


        return Dict(
            :model => Dict(
                :parameters => Dict(pairs(model_params))
            ),

            :metrics => Dict(
                :embedding => Dict(
                    :n_clusters => length(unique(assignments)),
                    :quality => embed_eval,
                    :mean_norm => mean(norm.(eachrow(embeddings))),
                    :var_norm => var(norm.(eachrow(embeddings))),
                ),
                :clustering => Dict(
                    :intra_cluster => Dict(
                        :per_view => intra_rates,
                        :composite => composite_rates
                    )
                )
            ),

            :baseline_metrics => Dict(
                :embedding => Dict(
                    :n_clusters => length(unique(base_clusters)),
                    :quality => Dict(
                        :modularity => modularity(composite_graph, base_clusters),
                        :conductance => cluster_conductance.(
                            Ref(composite_graph),
                            Ref(base_clusters),
                            unique(base_clusters)
                        ) |> mean
                    )
                ),
                :clustering => Dict(
                    :intra_cluster => Dict(
                        :per_view => intra_cluster_rate(base_clusters, views, names),
                        :composite => intra_cluster_rate(base_clusters, composite_graph)
                    )
                )
            )
        )
    end
end


