output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.drill.name
}

output "kubeconfig_command" {
  description = "Adds the cluster to kubeconfig under the context the drill script requires."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.drill.name} --alias restore-drill"
}
