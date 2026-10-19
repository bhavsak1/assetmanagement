
export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[]

export type Database = {
  
  "public": {
          Tables: {
            "domain_operation": {
                  Row: {
                    "code": string,"created_at": string,"id": string,"security_domain_id": string,"sort_order": number,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "code": string,"created_at"?: string,"id"?: string,"security_domain_id": string,"sort_order"?: number,"updated_at"?: string
                  }
                  Update: {
                    "code"?: string,"created_at"?: string,"id"?: string,"security_domain_id"?: string,"sort_order"?: number,"updated_at"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "domain_operation_security_domain_id_fkey"
      columns: ["security_domain_id"]
isOneToOne: false
      referencedRelation: "security_domain"
      referencedColumns: ["id"]
    }
                  ]
                },"group_domain_policy": {
                  Row: {
                    "created_at": string,"created_by": string | null,"deleted_at": string | null,"domain_operation_id": string,"id": string,"security_group_id": string,"tenant_id": string,"updated_at": string,"updated_by": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"created_by"?: string | null,"deleted_at"?: string | null,"domain_operation_id": string,"id"?: string,"security_group_id": string,"tenant_id": string,"updated_at"?: string,"updated_by"?: string | null
                  }
                  Update: {
                    "created_at"?: string,"created_by"?: string | null,"deleted_at"?: string | null,"domain_operation_id"?: string,"id"?: string,"security_group_id"?: string,"tenant_id"?: string,"updated_at"?: string,"updated_by"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "group_domain_policy_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "group_domain_policy_domain_operation_id_fkey"
      columns: ["domain_operation_id"]
isOneToOne: false
      referencedRelation: "domain_operation"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "group_domain_policy_tenant_id_security_group_id_fkey"
      columns: ["tenant_id","security_group_id"]
isOneToOne: false
      referencedRelation: "security_group"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "group_domain_policy_updated_by_fkey"
      columns: ["updated_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    }
                  ]
                },"rls_sample": {
                  Row: {
                    "created_at": string,"created_by": string | null,"deleted_at": string | null,"id": string,"name": string,"parent_id": string | null,"tenant_id": string,"updated_at": string,"updated_by": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"created_by"?: string | null,"deleted_at"?: string | null,"id"?: string,"name": string,"parent_id"?: string | null,"tenant_id": string,"updated_at"?: string,"updated_by"?: string | null
                  }
                  Update: {
                    "created_at"?: string,"created_by"?: string | null,"deleted_at"?: string | null,"id"?: string,"name"?: string,"parent_id"?: string | null,"tenant_id"?: string,"updated_at"?: string,"updated_by"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "rls_sample_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "rls_sample_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenant"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "rls_sample_tenant_id_parent_id_fkey"
      columns: ["tenant_id","parent_id"]
isOneToOne: false
      referencedRelation: "rls_sample"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "rls_sample_updated_by_fkey"
      columns: ["updated_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    }
                  ]
                },"security_domain": {
                  Row: {
                    "code": string,"created_at": string,"description": string,"entity": string,"id": string,"is_system": boolean,"kind": string,"updated_at": string
                  }
                  ComputedFields: never
                  Insert: {
                    "code": string,"created_at"?: string,"description": string,"entity": string,"id"?: string,"is_system"?: boolean,"kind": string,"updated_at"?: string
                  }
                  Update: {
                    "code"?: string,"created_at"?: string,"description"?: string,"entity"?: string,"id"?: string,"is_system"?: boolean,"kind"?: string,"updated_at"?: string
                  }
                  Relationships: [
                    
                  ]
                },"security_group": {
                  Row: {
                    "code": string,"created_at": string,"created_by": string | null,"deleted_at": string | null,"description": string | null,"group_type": string,"id": string,"name": string,"template_code": string | null,"tenant_id": string,"updated_at": string,"updated_by": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "code": string,"created_at"?: string,"created_by"?: string | null,"deleted_at"?: string | null,"description"?: string | null,"group_type"?: string,"id"?: string,"name": string,"template_code"?: string | null,"tenant_id": string,"updated_at"?: string,"updated_by"?: string | null
                  }
                  Update: {
                    "code"?: string,"created_at"?: string,"created_by"?: string | null,"deleted_at"?: string | null,"description"?: string | null,"group_type"?: string,"id"?: string,"name"?: string,"template_code"?: string | null,"tenant_id"?: string,"updated_at"?: string,"updated_by"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "security_group_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "security_group_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenant"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "security_group_updated_by_fkey"
      columns: ["updated_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    }
                  ]
                },"tenant": {
                  Row: {
                    "created_at": string,"created_by": string | null,"currency_code": string,"date_format": string,"deleted_at": string | null,"id": string,"locale": string,"name": string,"slug": string,"status": string,"time_zone": string,"updated_at": string,"updated_by": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"created_by"?: string | null,"currency_code": string,"date_format": string,"deleted_at"?: string | null,"id"?: string,"locale"?: string,"name": string,"slug": string,"status"?: string,"time_zone": string,"updated_at"?: string,"updated_by"?: string | null
                  }
                  Update: {
                    "created_at"?: string,"created_by"?: string | null,"currency_code"?: string,"date_format"?: string,"deleted_at"?: string | null,"id"?: string,"locale"?: string,"name"?: string,"slug"?: string,"status"?: string,"time_zone"?: string,"updated_at"?: string,"updated_by"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "tenant_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "tenant_updated_by_fkey"
      columns: ["updated_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    }
                  ]
                },"tenant_entitlement": {
                  Row: {
                    "created_at": string,"created_by": string | null,"deleted_at": string | null,"feature_code": string,"id": string,"limit_value": number | null,"tenant_id": string,"updated_at": string,"updated_by": string | null,"valid_from": string,"valid_to": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"created_by"?: string | null,"deleted_at"?: string | null,"feature_code": string,"id"?: string,"limit_value"?: number | null,"tenant_id": string,"updated_at"?: string,"updated_by"?: string | null,"valid_from"?: string,"valid_to"?: string | null
                  }
                  Update: {
                    "created_at"?: string,"created_by"?: string | null,"deleted_at"?: string | null,"feature_code"?: string,"id"?: string,"limit_value"?: number | null,"tenant_id"?: string,"updated_at"?: string,"updated_by"?: string | null,"valid_from"?: string,"valid_to"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "tenant_entitlement_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "tenant_entitlement_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenant"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "tenant_entitlement_updated_by_fkey"
      columns: ["updated_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    }
                  ]
                },"tenant_membership": {
                  Row: {
                    "created_at": string,"created_by": string | null,"deleted_at": string | null,"id": string,"permission_version": number,"status": string,"tenant_id": string,"updated_at": string,"updated_by": string | null,"user_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"created_by"?: string | null,"deleted_at"?: string | null,"id"?: string,"permission_version"?: number,"status"?: string,"tenant_id": string,"updated_at"?: string,"updated_by"?: string | null,"user_id": string
                  }
                  Update: {
                    "created_at"?: string,"created_by"?: string | null,"deleted_at"?: string | null,"id"?: string,"permission_version"?: number,"status"?: string,"tenant_id"?: string,"updated_at"?: string,"updated_by"?: string | null,"user_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "tenant_membership_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "tenant_membership_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenant"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "tenant_membership_updated_by_fkey"
      columns: ["updated_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "tenant_membership_user_id_fkey"
      columns: ["user_id"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    }
                  ]
                },"user_group_assignment": {
                  Row: {
                    "created_at": string,"created_by": string | null,"deleted_at": string | null,"effective_from": string,"effective_to": string | null,"id": string,"security_group_id": string,"tenant_id": string,"updated_at": string,"updated_by": string | null,"user_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"created_by"?: string | null,"deleted_at"?: string | null,"effective_from"?: string,"effective_to"?: string | null,"id"?: string,"security_group_id": string,"tenant_id": string,"updated_at"?: string,"updated_by"?: string | null,"user_id": string
                  }
                  Update: {
                    "created_at"?: string,"created_by"?: string | null,"deleted_at"?: string | null,"effective_from"?: string,"effective_to"?: string | null,"id"?: string,"security_group_id"?: string,"tenant_id"?: string,"updated_at"?: string,"updated_by"?: string | null,"user_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "user_group_assignment_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "user_group_assignment_tenant_id_security_group_id_fkey"
      columns: ["tenant_id","security_group_id"]
isOneToOne: false
      referencedRelation: "security_group"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "user_group_assignment_tenant_id_user_id_fkey"
      columns: ["tenant_id","user_id"]
isOneToOne: false
      referencedRelation: "tenant_membership"
      referencedColumns: ["tenant_id","user_id"]
    },{
      foreignKeyName: "user_group_assignment_updated_by_fkey"
      columns: ["updated_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "user_group_assignment_user_id_fkey"
      columns: ["user_id"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    }
                  ]
                },"user_profile": {
                  Row: {
                    "created_at": string,"created_by": string | null,"deleted_at": string | null,"display_name": string,"email": string,"id": string,"updated_at": string,"updated_by": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"created_by"?: string | null,"deleted_at"?: string | null,"display_name": string,"email": string,"id": string,"updated_at"?: string,"updated_by"?: string | null
                  }
                  Update: {
                    "created_at"?: string,"created_by"?: string | null,"deleted_at"?: string | null,"display_name"?: string,"email"?: string,"id"?: string,"updated_at"?: string,"updated_by"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "user_profile_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "user_profile_updated_by_fkey"
      columns: ["updated_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    }
                  ]
                }
          }
          Views: {
            [_ in never]: never
          }
          Functions: {
            "select_tenant":
{ Args: { "p_tenant_id": string }; Returns: undefined
                           }
          }
          Enums: {
            [_ in never]: never
          }
          CompositeTypes: {
            [_ in never]: never
          }
        }
}

type DatabaseWithoutInternals = Omit<Database, '__InternalSupabase'>

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
  ? (DefaultSchema["Tables"] & DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
      Row: infer R
    }
    ? R
    : never
  : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
  ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
      Insert: infer I
    }
    ? I
    : never
  : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never
> = DefaultSchemaTableNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
  ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
      Update: infer U
    }
    ? U
    : never
  : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never
> = DefaultSchemaEnumNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
  ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
  : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never
> = PublicCompositeTypeNameOrOptions extends { schema: keyof DatabaseWithoutInternals }
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
  ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
  : never

export const Constants = {
  "public": {
          Enums: {
            
          }
        }
} as const
