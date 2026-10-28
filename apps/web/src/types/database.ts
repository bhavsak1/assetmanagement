
export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[]

export type Database = {
  
  "public": {
          Tables: {
            "asset": {
                  Row: {
                    "category_id": string,"coverage_state": string,"coverage_state_until": string | null,"created_at": string,"created_by": string | null,"criticality": string | null,"custom_values": NonNullable<Json>,"deleted_at": string | null,"id": string,"in_service_date": string | null,"location_changed_at": string | null,"location_id": string | null,"location_reason": string | null,"manufacturer": string | null,"model": string | null,"name": string,"oem_vendor_id": string | null,"om_vendor_id": string | null,"parent_asset_id": string | null,"purchase_currency": string | null,"purchase_date": string | null,"purchase_value": number | null,"quantity": number,"serial_number": string | null,"status": string,"status_changed_at": string | null,"status_id": string,"status_reason": string | null,"tag": string,"tenant_id": string,"updated_at": string,"updated_by": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "category_id": string,"coverage_state"?: string,"coverage_state_until"?: string | null,"created_at"?: string,"created_by"?: string | null,"criticality"?: string | null,"custom_values"?: NonNullable<Json>,"deleted_at"?: string | null,"id"?: string,"in_service_date"?: string | null,"location_changed_at"?: string | null,"location_id"?: string | null,"location_reason"?: string | null,"manufacturer"?: string | null,"model"?: string | null,"name": string,"oem_vendor_id"?: string | null,"om_vendor_id"?: string | null,"parent_asset_id"?: string | null,"purchase_currency"?: string | null,"purchase_date"?: string | null,"purchase_value"?: number | null,"quantity"?: number,"serial_number"?: string | null,"status"?: string,"status_changed_at"?: string | null,"status_id": string,"status_reason"?: string | null,"tag": string,"tenant_id": string,"updated_at"?: string,"updated_by"?: string | null
                  }
                  Update: {
                    "category_id"?: string,"coverage_state"?: string,"coverage_state_until"?: string | null,"created_at"?: string,"created_by"?: string | null,"criticality"?: string | null,"custom_values"?: NonNullable<Json>,"deleted_at"?: string | null,"id"?: string,"in_service_date"?: string | null,"location_changed_at"?: string | null,"location_id"?: string | null,"location_reason"?: string | null,"manufacturer"?: string | null,"model"?: string | null,"name"?: string,"oem_vendor_id"?: string | null,"om_vendor_id"?: string | null,"parent_asset_id"?: string | null,"purchase_currency"?: string | null,"purchase_date"?: string | null,"purchase_value"?: number | null,"quantity"?: number,"serial_number"?: string | null,"status"?: string,"status_changed_at"?: string | null,"status_id"?: string,"status_reason"?: string | null,"tag"?: string,"tenant_id"?: string,"updated_at"?: string,"updated_by"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "asset_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "asset_oem_vendor_fk"
      columns: ["tenant_id","oem_vendor_id"]
isOneToOne: false
      referencedRelation: "vendor"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "asset_oem_vendor_fk"
      columns: ["tenant_id","oem_vendor_id"]
isOneToOne: false
      referencedRelation: "vendor_view"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "asset_om_vendor_fk"
      columns: ["tenant_id","om_vendor_id"]
isOneToOne: false
      referencedRelation: "vendor"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "asset_om_vendor_fk"
      columns: ["tenant_id","om_vendor_id"]
isOneToOne: false
      referencedRelation: "vendor_view"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "asset_status_fk"
      columns: ["tenant_id","status_id","status"]
isOneToOne: false
      referencedRelation: "asset_status"
      referencedColumns: ["tenant_id","id","system_status"]
    },{
      foreignKeyName: "asset_tenant_id_category_id_fkey"
      columns: ["tenant_id","category_id"]
isOneToOne: false
      referencedRelation: "asset_category"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "asset_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenant"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "asset_tenant_id_location_id_fkey"
      columns: ["tenant_id","location_id"]
isOneToOne: false
      referencedRelation: "location"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "asset_tenant_id_parent_asset_id_fkey"
      columns: ["tenant_id","parent_asset_id"]
isOneToOne: false
      referencedRelation: "asset"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "asset_tenant_id_parent_asset_id_fkey"
      columns: ["tenant_id","parent_asset_id"]
isOneToOne: false
      referencedRelation: "asset_view"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "asset_updated_by_fkey"
      columns: ["updated_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    }
                  ]
                },"asset_attachment": {
                  Row: {
                    "asset_id": string,"created_at": string,"created_by": string | null,"deleted_at": string | null,"file_name": string,"id": string,"mime_type": string,"object_path": string | null,"size_bytes": number,"tenant_id": string,"updated_at": string,"updated_by": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "asset_id": string,"created_at"?: string,"created_by"?: string | null,"deleted_at"?: string | null,"file_name": string,"id"?: string,"mime_type": string,"object_path"?: never,"size_bytes": number,"tenant_id": string,"updated_at"?: string,"updated_by"?: string | null
                  }
                  Update: {
                    "asset_id"?: string,"created_at"?: string,"created_by"?: string | null,"deleted_at"?: string | null,"file_name"?: string,"id"?: string,"mime_type"?: string,"object_path"?: never,"size_bytes"?: number,"tenant_id"?: string,"updated_at"?: string,"updated_by"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "asset_attachment_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "asset_attachment_tenant_id_asset_id_fkey"
      columns: ["tenant_id","asset_id"]
isOneToOne: false
      referencedRelation: "asset"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "asset_attachment_tenant_id_asset_id_fkey"
      columns: ["tenant_id","asset_id"]
isOneToOne: false
      referencedRelation: "asset_view"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "asset_attachment_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenant"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "asset_attachment_updated_by_fkey"
      columns: ["updated_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    }
                  ]
                },"asset_category": {
                  Row: {
                    "code": string | null,"created_at": string,"created_by": string | null,"default_obligations": Json | null,"default_warranty_months": number | null,"deleted_at": string | null,"description": string | null,"id": string,"is_active": boolean,"name": string,"oem_vendor_ids": (string)[],"om_vendor_ids": (string)[],"parent_id": string | null,"status_ids": (string)[] | null,"tenant_id": string,"updated_at": string,"updated_by": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "code"?: string | null,"created_at"?: string,"created_by"?: string | null,"default_obligations"?: Json | null,"default_warranty_months"?: number | null,"deleted_at"?: string | null,"description"?: string | null,"id"?: string,"is_active"?: boolean,"name": string,"oem_vendor_ids"?: (string)[],"om_vendor_ids"?: (string)[],"parent_id"?: string | null,"status_ids"?: (string)[] | null,"tenant_id": string,"updated_at"?: string,"updated_by"?: string | null
                  }
                  Update: {
                    "code"?: string | null,"created_at"?: string,"created_by"?: string | null,"default_obligations"?: Json | null,"default_warranty_months"?: number | null,"deleted_at"?: string | null,"description"?: string | null,"id"?: string,"is_active"?: boolean,"name"?: string,"oem_vendor_ids"?: (string)[],"om_vendor_ids"?: (string)[],"parent_id"?: string | null,"status_ids"?: (string)[] | null,"tenant_id"?: string,"updated_at"?: string,"updated_by"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "asset_category_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "asset_category_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenant"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "asset_category_tenant_id_parent_id_fkey"
      columns: ["tenant_id","parent_id"]
isOneToOne: false
      referencedRelation: "asset_category"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "asset_category_updated_by_fkey"
      columns: ["updated_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    }
                  ]
                },"asset_status": {
                  Row: {
                    "code": string,"created_at": string,"created_by": string | null,"deleted_at": string | null,"id": string,"is_active": boolean,"label": string,"system_status": string,"tenant_id": string,"tone": string,"updated_at": string,"updated_by": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "code": string,"created_at"?: string,"created_by"?: string | null,"deleted_at"?: string | null,"id"?: string,"is_active"?: boolean,"label": string,"system_status": string,"tenant_id": string,"tone"?: string,"updated_at"?: string,"updated_by"?: string | null
                  }
                  Update: {
                    "code"?: string,"created_at"?: string,"created_by"?: string | null,"deleted_at"?: string | null,"id"?: string,"is_active"?: boolean,"label"?: string,"system_status"?: string,"tenant_id"?: string,"tone"?: string,"updated_at"?: string,"updated_by"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "asset_status_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "asset_status_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenant"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "asset_status_updated_by_fkey"
      columns: ["updated_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    }
                  ]
                },"audit_log": {
                  Row: {
                    "action": string,"actor_type": string,"actor_user_id": string | null,"category": string,"id": string,"new_data": Json | null,"occurred_at": string,"old_data": Json | null,"reason": string | null,"record_id": string,"table_name": string,"tenant_id": string,"transaction_id": number
                  }
                  ComputedFields: never
                  Insert: {
                    "action": string,"actor_type": string,"actor_user_id"?: string | null,"category": string,"id"?: string,"new_data"?: Json | null,"occurred_at"?: string,"old_data"?: Json | null,"reason"?: string | null,"record_id": string,"table_name": string,"tenant_id": string,"transaction_id"?: number
                  }
                  Update: {
                    "action"?: string,"actor_type"?: string,"actor_user_id"?: string | null,"category"?: string,"id"?: string,"new_data"?: Json | null,"occurred_at"?: string,"old_data"?: Json | null,"reason"?: string | null,"record_id"?: string,"table_name"?: string,"tenant_id"?: string,"transaction_id"?: number
                  }
                  Relationships: [
                    {
      foreignKeyName: "audit_log_actor_user_id_fkey"
      columns: ["actor_user_id"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "audit_log_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenant"
      referencedColumns: ["id"]
    }
                  ]
                },"coverage": {
                  Row: {
                    "contract_currency": string | null,"contract_value": number | null,"coverage_type": string,"created_at": string,"created_by": string | null,"deleted_at": string | null,"end_date": string,"id": string,"notes": string | null,"reference": string | null,"renews_coverage_id": string | null,"start_date": string,"tenant_id": string,"updated_at": string,"updated_by": string | null,"vendor_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "contract_currency"?: string | null,"contract_value"?: number | null,"coverage_type": string,"created_at"?: string,"created_by"?: string | null,"deleted_at"?: string | null,"end_date": string,"id"?: string,"notes"?: string | null,"reference"?: string | null,"renews_coverage_id"?: string | null,"start_date": string,"tenant_id": string,"updated_at"?: string,"updated_by"?: string | null,"vendor_id": string
                  }
                  Update: {
                    "contract_currency"?: string | null,"contract_value"?: number | null,"coverage_type"?: string,"created_at"?: string,"created_by"?: string | null,"deleted_at"?: string | null,"end_date"?: string,"id"?: string,"notes"?: string | null,"reference"?: string | null,"renews_coverage_id"?: string | null,"start_date"?: string,"tenant_id"?: string,"updated_at"?: string,"updated_by"?: string | null,"vendor_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "coverage_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "coverage_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenant"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "coverage_tenant_id_renews_coverage_id_fkey"
      columns: ["tenant_id","renews_coverage_id"]
isOneToOne: false
      referencedRelation: "coverage"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "coverage_tenant_id_renews_coverage_id_fkey"
      columns: ["tenant_id","renews_coverage_id"]
isOneToOne: false
      referencedRelation: "coverage_view"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "coverage_tenant_id_vendor_id_fkey"
      columns: ["tenant_id","vendor_id"]
isOneToOne: false
      referencedRelation: "vendor"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "coverage_tenant_id_vendor_id_fkey"
      columns: ["tenant_id","vendor_id"]
isOneToOne: false
      referencedRelation: "vendor_view"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "coverage_updated_by_fkey"
      columns: ["updated_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    }
                  ]
                },"coverage_asset": {
                  Row: {
                    "asset_id": string,"coverage_id": string,"created_at": string,"created_by": string | null,"deleted_at": string | null,"id": string,"tenant_id": string,"updated_at": string,"updated_by": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "asset_id": string,"coverage_id": string,"created_at"?: string,"created_by"?: string | null,"deleted_at"?: string | null,"id"?: string,"tenant_id": string,"updated_at"?: string,"updated_by"?: string | null
                  }
                  Update: {
                    "asset_id"?: string,"coverage_id"?: string,"created_at"?: string,"created_by"?: string | null,"deleted_at"?: string | null,"id"?: string,"tenant_id"?: string,"updated_at"?: string,"updated_by"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "coverage_asset_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "coverage_asset_tenant_id_asset_id_fkey"
      columns: ["tenant_id","asset_id"]
isOneToOne: false
      referencedRelation: "asset"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "coverage_asset_tenant_id_asset_id_fkey"
      columns: ["tenant_id","asset_id"]
isOneToOne: false
      referencedRelation: "asset_view"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "coverage_asset_tenant_id_coverage_id_fkey"
      columns: ["tenant_id","coverage_id"]
isOneToOne: false
      referencedRelation: "coverage"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "coverage_asset_tenant_id_coverage_id_fkey"
      columns: ["tenant_id","coverage_id"]
isOneToOne: false
      referencedRelation: "coverage_view"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "coverage_asset_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenant"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "coverage_asset_updated_by_fkey"
      columns: ["updated_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    }
                  ]
                },"domain_operation": {
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
                },"field_definition": {
                  Row: {
                    "category_id": string | null,"created_at": string,"created_by": string | null,"deleted_at": string | null,"entity": string,"id": string,"is_active": boolean,"is_required": boolean,"key": string,"label": string,"options": NonNullable<Json>,"pattern": string | null,"security_domain_id": string,"sort_order": number,"tenant_id": string,"type": string,"unit": string | null,"updated_at": string,"updated_by": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "category_id"?: string | null,"created_at"?: string,"created_by"?: string | null,"deleted_at"?: string | null,"entity": string,"id"?: string,"is_active"?: boolean,"is_required"?: boolean,"key": string,"label": string,"options"?: NonNullable<Json>,"pattern"?: string | null,"security_domain_id": string,"sort_order"?: number,"tenant_id": string,"type": string,"unit"?: string | null,"updated_at"?: string,"updated_by"?: string | null
                  }
                  Update: {
                    "category_id"?: string | null,"created_at"?: string,"created_by"?: string | null,"deleted_at"?: string | null,"entity"?: string,"id"?: string,"is_active"?: boolean,"is_required"?: boolean,"key"?: string,"label"?: string,"options"?: NonNullable<Json>,"pattern"?: string | null,"security_domain_id"?: string,"sort_order"?: number,"tenant_id"?: string,"type"?: string,"unit"?: string | null,"updated_at"?: string,"updated_by"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "field_definition_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "field_definition_security_domain_id_entity_fkey"
      columns: ["security_domain_id","entity"]
isOneToOne: false
      referencedRelation: "security_domain"
      referencedColumns: ["id","entity"]
    },{
      foreignKeyName: "field_definition_tenant_id_category_id_fkey"
      columns: ["tenant_id","category_id"]
isOneToOne: false
      referencedRelation: "asset_category"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "field_definition_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenant"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "field_definition_updated_by_fkey"
      columns: ["updated_by"]
isOneToOne: false
      referencedRelation: "user_profile"
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
                },"location": {
                  Row: {
                    "active": boolean,"code": string | null,"created_at": string,"created_by": string | null,"deleted_at": string | null,"id": string,"location_type": string | null,"name": string,"parent_id": string | null,"tenant_id": string,"updated_at": string,"updated_by": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "active"?: boolean,"code"?: string | null,"created_at"?: string,"created_by"?: string | null,"deleted_at"?: string | null,"id"?: string,"location_type"?: string | null,"name": string,"parent_id"?: string | null,"tenant_id": string,"updated_at"?: string,"updated_by"?: string | null
                  }
                  Update: {
                    "active"?: boolean,"code"?: string | null,"created_at"?: string,"created_by"?: string | null,"deleted_at"?: string | null,"id"?: string,"location_type"?: string | null,"name"?: string,"parent_id"?: string | null,"tenant_id"?: string,"updated_at"?: string,"updated_by"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "location_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "location_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenant"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "location_tenant_id_parent_id_fkey"
      columns: ["tenant_id","parent_id"]
isOneToOne: false
      referencedRelation: "location"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "location_updated_by_fkey"
      columns: ["updated_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    }
                  ]
                },"obligation": {
                  Row: {
                    "anchor": string,"asset_id": string,"created_at": string,"created_by": string | null,"deleted_at": string | null,"due_state": string,"due_state_until": string | null,"first_due_date": string,"id": string,"interval_count": number,"interval_unit": string,"is_active": boolean,"last_done_date": string | null,"name": string,"next_due_date": string,"notes": string | null,"obligation_type": string,"tenant_id": string,"updated_at": string,"updated_by": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "anchor": string,"asset_id": string,"created_at"?: string,"created_by"?: string | null,"deleted_at"?: string | null,"due_state"?: string,"due_state_until"?: string | null,"first_due_date": string,"id"?: string,"interval_count": number,"interval_unit": string,"is_active"?: boolean,"last_done_date"?: string | null,"name": string,"next_due_date": string,"notes"?: string | null,"obligation_type": string,"tenant_id": string,"updated_at"?: string,"updated_by"?: string | null
                  }
                  Update: {
                    "anchor"?: string,"asset_id"?: string,"created_at"?: string,"created_by"?: string | null,"deleted_at"?: string | null,"due_state"?: string,"due_state_until"?: string | null,"first_due_date"?: string,"id"?: string,"interval_count"?: number,"interval_unit"?: string,"is_active"?: boolean,"last_done_date"?: string | null,"name"?: string,"next_due_date"?: string,"notes"?: string | null,"obligation_type"?: string,"tenant_id"?: string,"updated_at"?: string,"updated_by"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "obligation_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "obligation_tenant_id_asset_id_fkey"
      columns: ["tenant_id","asset_id"]
isOneToOne: false
      referencedRelation: "asset"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "obligation_tenant_id_asset_id_fkey"
      columns: ["tenant_id","asset_id"]
isOneToOne: false
      referencedRelation: "asset_view"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "obligation_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenant"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "obligation_updated_by_fkey"
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
                },"saved_view": {
                  Row: {
                    "created_at": string,"created_by": string | null,"deleted_at": string | null,"entity": string,"filters": NonNullable<Json>,"id": string,"name": string,"sort": string,"tenant_id": string,"updated_at": string,"updated_by": string | null,"user_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"created_by"?: string | null,"deleted_at"?: string | null,"entity": string,"filters"?: NonNullable<Json>,"id"?: string,"name": string,"sort"?: string,"tenant_id": string,"updated_at"?: string,"updated_by"?: string | null,"user_id"?: string
                  }
                  Update: {
                    "created_at"?: string,"created_by"?: string | null,"deleted_at"?: string | null,"entity"?: string,"filters"?: NonNullable<Json>,"id"?: string,"name"?: string,"sort"?: string,"tenant_id"?: string,"updated_at"?: string,"updated_by"?: string | null,"user_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "saved_view_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "saved_view_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenant"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "saved_view_tenant_id_user_id_fkey"
      columns: ["tenant_id","user_id"]
isOneToOne: false
      referencedRelation: "tenant_membership"
      referencedColumns: ["tenant_id","user_id"]
    },{
      foreignKeyName: "saved_view_updated_by_fkey"
      columns: ["updated_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "saved_view_user_id_fkey"
      columns: ["user_id"]
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
                },"service_record": {
                  Row: {
                    "advanced": boolean,"asset_id": string,"certificate_expiry": string | null,"cost_amount": number | null,"cost_currency": string | null,"created_at": string,"created_by": string | null,"deleted_at": string | null,"done_by_user_id": string | null,"done_on": string,"id": string,"notes": string | null,"obligation_id": string,"outcome": string | null,"prev_last_done_date": string | null,"tenant_id": string,"updated_at": string,"updated_by": string | null,"vendor_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "advanced": boolean,"asset_id": string,"certificate_expiry"?: string | null,"cost_amount"?: number | null,"cost_currency"?: string | null,"created_at"?: string,"created_by"?: string | null,"deleted_at"?: string | null,"done_by_user_id"?: string | null,"done_on": string,"id"?: string,"notes"?: string | null,"obligation_id": string,"outcome"?: string | null,"prev_last_done_date"?: string | null,"tenant_id": string,"updated_at"?: string,"updated_by"?: string | null,"vendor_id"?: string | null
                  }
                  Update: {
                    "advanced"?: boolean,"asset_id"?: string,"certificate_expiry"?: string | null,"cost_amount"?: number | null,"cost_currency"?: string | null,"created_at"?: string,"created_by"?: string | null,"deleted_at"?: string | null,"done_by_user_id"?: string | null,"done_on"?: string,"id"?: string,"notes"?: string | null,"obligation_id"?: string,"outcome"?: string | null,"prev_last_done_date"?: string | null,"tenant_id"?: string,"updated_at"?: string,"updated_by"?: string | null,"vendor_id"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "service_record_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "service_record_done_by_user_id_fkey"
      columns: ["done_by_user_id"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "service_record_tenant_id_asset_id_fkey"
      columns: ["tenant_id","asset_id"]
isOneToOne: false
      referencedRelation: "asset"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "service_record_tenant_id_asset_id_fkey"
      columns: ["tenant_id","asset_id"]
isOneToOne: false
      referencedRelation: "asset_view"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "service_record_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenant"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "service_record_tenant_id_obligation_id_fkey"
      columns: ["tenant_id","obligation_id"]
isOneToOne: false
      referencedRelation: "obligation"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "service_record_tenant_id_vendor_id_fkey"
      columns: ["tenant_id","vendor_id"]
isOneToOne: false
      referencedRelation: "vendor"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "service_record_tenant_id_vendor_id_fkey"
      columns: ["tenant_id","vendor_id"]
isOneToOne: false
      referencedRelation: "vendor_view"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "service_record_updated_by_fkey"
      columns: ["updated_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    }
                  ]
                },"tenant": {
                  Row: {
                    "asset_tag_pattern": string,"coverage_expiring_days": number,"coverage_refresh_after": string | null,"created_at": string,"created_by": string | null,"currency_code": string,"date_format": string,"deleted_at": string | null,"fiscal_year_start_month": number,"id": string,"locale": string,"name": string,"obligation_due_soon_days": number,"obligation_refresh_after": string | null,"required_asset_fields": (string)[],"slug": string,"status": string,"time_zone": string,"updated_at": string,"updated_by": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "asset_tag_pattern"?: string,"coverage_expiring_days"?: number,"coverage_refresh_after"?: string | null,"created_at"?: string,"created_by"?: string | null,"currency_code": string,"date_format": string,"deleted_at"?: string | null,"fiscal_year_start_month": number,"id"?: string,"locale": string,"name": string,"obligation_due_soon_days"?: number,"obligation_refresh_after"?: string | null,"required_asset_fields"?: (string)[],"slug": string,"status"?: string,"time_zone": string,"updated_at"?: string,"updated_by"?: string | null
                  }
                  Update: {
                    "asset_tag_pattern"?: string,"coverage_expiring_days"?: number,"coverage_refresh_after"?: string | null,"created_at"?: string,"created_by"?: string | null,"currency_code"?: string,"date_format"?: string,"deleted_at"?: string | null,"fiscal_year_start_month"?: number,"id"?: string,"locale"?: string,"name"?: string,"obligation_due_soon_days"?: number,"obligation_refresh_after"?: string | null,"required_asset_fields"?: (string)[],"slug"?: string,"status"?: string,"time_zone"?: string,"updated_at"?: string,"updated_by"?: string | null
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
                },"vendor": {
                  Row: {
                    "address": string | null,"code": string | null,"created_at": string,"created_by": string | null,"custom_values": NonNullable<Json>,"deleted_at": string | null,"email": string | null,"id": string,"is_active": boolean,"name": string,"notes": string | null,"phone": string | null,"roles": (string)[],"tenant_id": string,"updated_at": string,"updated_by": string | null,"website": string | null
                  }
                  ComputedFields: never
                  Insert: {
                    "address"?: string | null,"code"?: string | null,"created_at"?: string,"created_by"?: string | null,"custom_values"?: NonNullable<Json>,"deleted_at"?: string | null,"email"?: string | null,"id"?: string,"is_active"?: boolean,"name": string,"notes"?: string | null,"phone"?: string | null,"roles"?: (string)[],"tenant_id": string,"updated_at"?: string,"updated_by"?: string | null,"website"?: string | null
                  }
                  Update: {
                    "address"?: string | null,"code"?: string | null,"created_at"?: string,"created_by"?: string | null,"custom_values"?: NonNullable<Json>,"deleted_at"?: string | null,"email"?: string | null,"id"?: string,"is_active"?: boolean,"name"?: string,"notes"?: string | null,"phone"?: string | null,"roles"?: (string)[],"tenant_id"?: string,"updated_at"?: string,"updated_by"?: string | null,"website"?: string | null
                  }
                  Relationships: [
                    {
      foreignKeyName: "vendor_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "vendor_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenant"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "vendor_updated_by_fkey"
      columns: ["updated_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    }
                  ]
                },"vendor_contact": {
                  Row: {
                    "created_at": string,"created_by": string | null,"deleted_at": string | null,"email": string | null,"id": string,"is_primary": boolean,"name": string,"phone": string | null,"tenant_id": string,"title": string | null,"updated_at": string,"updated_by": string | null,"vendor_id": string
                  }
                  ComputedFields: never
                  Insert: {
                    "created_at"?: string,"created_by"?: string | null,"deleted_at"?: string | null,"email"?: string | null,"id"?: string,"is_primary"?: boolean,"name": string,"phone"?: string | null,"tenant_id": string,"title"?: string | null,"updated_at"?: string,"updated_by"?: string | null,"vendor_id": string
                  }
                  Update: {
                    "created_at"?: string,"created_by"?: string | null,"deleted_at"?: string | null,"email"?: string | null,"id"?: string,"is_primary"?: boolean,"name"?: string,"phone"?: string | null,"tenant_id"?: string,"title"?: string | null,"updated_at"?: string,"updated_by"?: string | null,"vendor_id"?: string
                  }
                  Relationships: [
                    {
      foreignKeyName: "vendor_contact_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "vendor_contact_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenant"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "vendor_contact_tenant_id_vendor_id_fkey"
      columns: ["tenant_id","vendor_id"]
isOneToOne: false
      referencedRelation: "vendor"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "vendor_contact_tenant_id_vendor_id_fkey"
      columns: ["tenant_id","vendor_id"]
isOneToOne: false
      referencedRelation: "vendor_view"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "vendor_contact_updated_by_fkey"
      columns: ["updated_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    }
                  ]
                }
          }
          Views: {
            "asset_view": {
                  Row: {
                    "category_id": string | null,"coverage_state": string | null,"created_at": string | null,"created_by": string | null,"criticality": string | null,"custom_values": Json | null,"id": string | null,"in_service_date": string | null,"location_changed_at": string | null,"location_id": string | null,"location_reason": string | null,"manufacturer": string | null,"model": string | null,"name": string | null,"oem_vendor_id": string | null,"om_vendor_id": string | null,"parent_asset_id": string | null,"purchase_currency": string | null,"purchase_date": string | null,"purchase_value": number | null,"quantity": number | null,"serial_number": string | null,"status": string | null,"status_changed_at": string | null,"status_id": string | null,"status_reason": string | null,"tag": string | null,"tenant_id": string | null,"updated_at": string | null,"updated_by": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "category_id"?: string | null,"coverage_state"?: string | null,"created_at"?: string | null,"created_by"?: string | null,"criticality"?: string | null,"custom_values"?: never,"id"?: string | null,"in_service_date"?: string | null,"location_changed_at"?: string | null,"location_id"?: string | null,"location_reason"?: string | null,"manufacturer"?: string | null,"model"?: string | null,"name"?: string | null,"oem_vendor_id"?: string | null,"om_vendor_id"?: string | null,"parent_asset_id"?: string | null,"purchase_currency"?: never,"purchase_date"?: string | null,"purchase_value"?: never,"quantity"?: number | null,"serial_number"?: string | null,"status"?: string | null,"status_changed_at"?: string | null,"status_id"?: string | null,"status_reason"?: string | null,"tag"?: string | null,"tenant_id"?: string | null,"updated_at"?: string | null,"updated_by"?: string | null
                         }
                        Update: {
                           "category_id"?: string | null,"coverage_state"?: string | null,"created_at"?: string | null,"created_by"?: string | null,"criticality"?: string | null,"custom_values"?: never,"id"?: string | null,"in_service_date"?: string | null,"location_changed_at"?: string | null,"location_id"?: string | null,"location_reason"?: string | null,"manufacturer"?: string | null,"model"?: string | null,"name"?: string | null,"oem_vendor_id"?: string | null,"om_vendor_id"?: string | null,"parent_asset_id"?: string | null,"purchase_currency"?: never,"purchase_date"?: string | null,"purchase_value"?: never,"quantity"?: number | null,"serial_number"?: string | null,"status"?: string | null,"status_changed_at"?: string | null,"status_id"?: string | null,"status_reason"?: string | null,"tag"?: string | null,"tenant_id"?: string | null,"updated_at"?: string | null,"updated_by"?: string | null
                         }
                        Relationships: [
                    {
      foreignKeyName: "asset_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "asset_oem_vendor_fk"
      columns: ["tenant_id","oem_vendor_id"]
isOneToOne: false
      referencedRelation: "vendor"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "asset_oem_vendor_fk"
      columns: ["tenant_id","oem_vendor_id"]
isOneToOne: false
      referencedRelation: "vendor_view"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "asset_om_vendor_fk"
      columns: ["tenant_id","om_vendor_id"]
isOneToOne: false
      referencedRelation: "vendor"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "asset_om_vendor_fk"
      columns: ["tenant_id","om_vendor_id"]
isOneToOne: false
      referencedRelation: "vendor_view"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "asset_status_fk"
      columns: ["tenant_id","status_id","status"]
isOneToOne: false
      referencedRelation: "asset_status"
      referencedColumns: ["tenant_id","id","system_status"]
    },{
      foreignKeyName: "asset_tenant_id_category_id_fkey"
      columns: ["tenant_id","category_id"]
isOneToOne: false
      referencedRelation: "asset_category"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "asset_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenant"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "asset_tenant_id_location_id_fkey"
      columns: ["tenant_id","location_id"]
isOneToOne: false
      referencedRelation: "location"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "asset_tenant_id_parent_asset_id_fkey"
      columns: ["tenant_id","parent_asset_id"]
isOneToOne: false
      referencedRelation: "asset"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "asset_tenant_id_parent_asset_id_fkey"
      columns: ["tenant_id","parent_asset_id"]
isOneToOne: false
      referencedRelation: "asset_view"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "asset_updated_by_fkey"
      columns: ["updated_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    }
                  ]
                },"coverage_view": {
                  Row: {
                    "contract_currency": string | null,"contract_value": number | null,"coverage_type": string | null,"created_at": string | null,"created_by": string | null,"end_date": string | null,"id": string | null,"notes": string | null,"reference": string | null,"renews_coverage_id": string | null,"start_date": string | null,"status": string | null,"tenant_id": string | null,"updated_at": string | null,"updated_by": string | null,"vendor_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "contract_currency"?: never,"contract_value"?: never,"coverage_type"?: string | null,"created_at"?: string | null,"created_by"?: string | null,"end_date"?: string | null,"id"?: string | null,"notes"?: string | null,"reference"?: string | null,"renews_coverage_id"?: string | null,"start_date"?: string | null,"status"?: never,"tenant_id"?: string | null,"updated_at"?: string | null,"updated_by"?: string | null,"vendor_id"?: string | null
                         }
                        Update: {
                           "contract_currency"?: never,"contract_value"?: never,"coverage_type"?: string | null,"created_at"?: string | null,"created_by"?: string | null,"end_date"?: string | null,"id"?: string | null,"notes"?: string | null,"reference"?: string | null,"renews_coverage_id"?: string | null,"start_date"?: string | null,"status"?: never,"tenant_id"?: string | null,"updated_at"?: string | null,"updated_by"?: string | null,"vendor_id"?: string | null
                         }
                        Relationships: [
                    {
      foreignKeyName: "coverage_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "coverage_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenant"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "coverage_tenant_id_renews_coverage_id_fkey"
      columns: ["tenant_id","renews_coverage_id"]
isOneToOne: false
      referencedRelation: "coverage"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "coverage_tenant_id_renews_coverage_id_fkey"
      columns: ["tenant_id","renews_coverage_id"]
isOneToOne: false
      referencedRelation: "coverage_view"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "coverage_tenant_id_vendor_id_fkey"
      columns: ["tenant_id","vendor_id"]
isOneToOne: false
      referencedRelation: "vendor"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "coverage_tenant_id_vendor_id_fkey"
      columns: ["tenant_id","vendor_id"]
isOneToOne: false
      referencedRelation: "vendor_view"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "coverage_updated_by_fkey"
      columns: ["updated_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    }
                  ]
                },"my_permission": {
                  Row: {
                    "domain": string | null,"operation": string | null
                  }
                  ComputedFields: never
                  Relationships: [
                    
                  ]
                },"service_record_view": {
                  Row: {
                    "advanced": boolean | null,"asset_id": string | null,"certificate_expiry": string | null,"cost_amount": number | null,"cost_currency": string | null,"created_at": string | null,"created_by": string | null,"done_by_user_id": string | null,"done_on": string | null,"id": string | null,"notes": string | null,"obligation_id": string | null,"outcome": string | null,"tenant_id": string | null,"updated_at": string | null,"updated_by": string | null,"vendor_id": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "advanced"?: boolean | null,"asset_id"?: string | null,"certificate_expiry"?: string | null,"cost_amount"?: never,"cost_currency"?: never,"created_at"?: string | null,"created_by"?: string | null,"done_by_user_id"?: string | null,"done_on"?: string | null,"id"?: string | null,"notes"?: string | null,"obligation_id"?: string | null,"outcome"?: string | null,"tenant_id"?: string | null,"updated_at"?: string | null,"updated_by"?: string | null,"vendor_id"?: string | null
                         }
                        Update: {
                           "advanced"?: boolean | null,"asset_id"?: string | null,"certificate_expiry"?: string | null,"cost_amount"?: never,"cost_currency"?: never,"created_at"?: string | null,"created_by"?: string | null,"done_by_user_id"?: string | null,"done_on"?: string | null,"id"?: string | null,"notes"?: string | null,"obligation_id"?: string | null,"outcome"?: string | null,"tenant_id"?: string | null,"updated_at"?: string | null,"updated_by"?: string | null,"vendor_id"?: string | null
                         }
                        Relationships: [
                    {
      foreignKeyName: "service_record_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "service_record_done_by_user_id_fkey"
      columns: ["done_by_user_id"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "service_record_tenant_id_asset_id_fkey"
      columns: ["tenant_id","asset_id"]
isOneToOne: false
      referencedRelation: "asset"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "service_record_tenant_id_asset_id_fkey"
      columns: ["tenant_id","asset_id"]
isOneToOne: false
      referencedRelation: "asset_view"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "service_record_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenant"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "service_record_tenant_id_obligation_id_fkey"
      columns: ["tenant_id","obligation_id"]
isOneToOne: false
      referencedRelation: "obligation"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "service_record_tenant_id_vendor_id_fkey"
      columns: ["tenant_id","vendor_id"]
isOneToOne: false
      referencedRelation: "vendor"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "service_record_tenant_id_vendor_id_fkey"
      columns: ["tenant_id","vendor_id"]
isOneToOne: false
      referencedRelation: "vendor_view"
      referencedColumns: ["tenant_id","id"]
    },{
      foreignKeyName: "service_record_updated_by_fkey"
      columns: ["updated_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    }
                  ]
                },"vendor_view": {
                  Row: {
                    "address": string | null,"code": string | null,"created_at": string | null,"created_by": string | null,"custom_values": Json | null,"email": string | null,"id": string | null,"is_active": boolean | null,"name": string | null,"notes": string | null,"phone": string | null,"roles": (string)[] | null,"tenant_id": string | null,"updated_at": string | null,"updated_by": string | null,"website": string | null
                  }
                  ComputedFields: never
                  Insert: {
                           "address"?: string | null,"code"?: string | null,"created_at"?: string | null,"created_by"?: string | null,"custom_values"?: never,"email"?: string | null,"id"?: string | null,"is_active"?: boolean | null,"name"?: string | null,"notes"?: string | null,"phone"?: string | null,"roles"?: (string)[] | null,"tenant_id"?: string | null,"updated_at"?: string | null,"updated_by"?: string | null,"website"?: string | null
                         }
                        Update: {
                           "address"?: string | null,"code"?: string | null,"created_at"?: string | null,"created_by"?: string | null,"custom_values"?: never,"email"?: string | null,"id"?: string | null,"is_active"?: boolean | null,"name"?: string | null,"notes"?: string | null,"phone"?: string | null,"roles"?: (string)[] | null,"tenant_id"?: string | null,"updated_at"?: string | null,"updated_by"?: string | null,"website"?: string | null
                         }
                        Relationships: [
                    {
      foreignKeyName: "vendor_created_by_fkey"
      columns: ["created_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "vendor_tenant_id_fkey"
      columns: ["tenant_id"]
isOneToOne: false
      referencedRelation: "tenant"
      referencedColumns: ["id"]
    },{
      foreignKeyName: "vendor_updated_by_fkey"
      columns: ["updated_by"]
isOneToOne: false
      referencedRelation: "user_profile"
      referencedColumns: ["id"]
    }
                  ]
                }
          }
          Functions: {
            "allowed_asset_statuses":
{ Args: { "p_asset_id": string }; Returns: string[]
                           },
"asset_attachments":
{ Args: { "p_asset_id": string }; Returns: {
              "created_at": string,"file_name": string,"id": string,"mime_type": string,"size_bytes": number,"uploaded_by": string
            }[]
                           },
"asset_coverage":
{ Args: { "p_asset_ids": (string)[] }; Returns: {
              "asset_id": string,"coverage_group": string,"coverage_id": string,"end_date": string,"start_date": string,"status": string,"vendor_id": string
            }[]
                           },
"asset_history":
{ Args: { "p_asset_id": string,"p_before"?: string,"p_before_id"?: string,"p_limit"?: number }; Returns: {
              "action": string,"actor_name": string,"actor_type": string,"hidden_fields": (string)[],"id": string,"new_data": Json,"occurred_at": string,"old_data": Json
            }[]
                           },
"category_defaults":
{ Args: { "p_category_id": string }; Returns: {
              "default_obligations": Json,"default_warranty_months": number,"obligations_from": string,"warranty_from": string
            }[]
                           },
"category_statuses":
{ Args: { "p_category_id"?: string }; Returns: (string)[]
                           },
"category_vendors":
{ Args: { "p_category_id": string,"p_role": string }; Returns: string[]
                           },
"change_asset_status":
{ Args: { "p_asset_id": string,"p_reason"?: string,"p_status": string }; Returns: undefined
                           } |
{ Args: { "p_asset_id": string,"p_reason"?: string,"p_status_id": string }; Returns: undefined
                           },
"complete_obligation":
{ Args: { "p_certificate_expiry"?: string,"p_cost"?: number,"p_currency"?: string,"p_done_by"?: string,"p_done_on": string,"p_notes"?: string,"p_obligation_id": string,"p_outcome"?: string,"p_vendor_id"?: string }; Returns: string
                           },
"count_assets":
{ Args: { "p_category_id"?: string,"p_coverage"?: string,"p_location_id"?: string,"p_status"?: string,"p_status_id"?: string,"p_term"?: string,"p_vendor_id"?: string }; Returns: number
                           },
"create_asset_with_warranty":
{ Args: { "p_asset": Json,"p_coverages": Json }; Returns: string
                           },
"field_domains":
{ Args: { "p_entity": string }; Returns: {
              "code": string,"id": string
            }[]
                           },
"list_assets":
{ Args: { "p_after_id"?: string,"p_after_value"?: string,"p_category_id"?: string,"p_coverage"?: string,"p_limit"?: number,"p_location_id"?: string,"p_sort"?: string,"p_status"?: string,"p_status_id"?: string,"p_term"?: string,"p_vendor_id"?: string }; Returns: {
              "category_id": string | null,
"coverage_state": string | null,
"created_at": string | null,
"created_by": string | null,
"criticality": string | null,
"custom_values": Json | null,
"id": string | null,
"in_service_date": string | null,
"location_changed_at": string | null,
"location_id": string | null,
"location_reason": string | null,
"manufacturer": string | null,
"model": string | null,
"name": string | null,
"oem_vendor_id": string | null,
"om_vendor_id": string | null,
"parent_asset_id": string | null,
"purchase_currency": string | null,
"purchase_date": string | null,
"purchase_value": number | null,
"quantity": number | null,
"serial_number": string | null,
"status": string | null,
"status_changed_at": string | null,
"status_id": string | null,
"status_reason": string | null,
"tag": string | null,
"tenant_id": string | null,
"updated_at": string | null,
"updated_by": string | null
            }[]
                          SetofOptions: {
        from: "*"
        to: "asset_view"
        isOneToOne: false
        isSetofReturn: true
      } },
"merge_vendor":
{ Args: { "p_from_id": string,"p_into_id": string }; Returns: undefined
                           },
"preview_asset_tag":
{ Args: { "p_category_id"?: string,"p_location_id"?: string,"p_pattern": string }; Returns: string
                           },
"select_tenant":
{ Args: { "p_tenant_id": string }; Returns: undefined
                           },
"service_history":
{ Args: { "p_asset_id": string,"p_obligation_id"?: string }; Returns: {
              "advanced": boolean,"certificate_expiry": string,"cost_amount": number,"cost_currency": string,"done_by_name": string,"done_by_user_id": string,"done_on": string,"id": string,"notes": string,"obligation_id": string,"obligation_name": string,"outcome": string,"vendor_id": string,"vendor_name": string
            }[]
                           },
"set_asset_tag_pattern":
{ Args: { "p_pattern": string }; Returns: undefined
                           },
"transfer_asset":
{ Args: { "p_asset_id": string,"p_reason": string,"p_to_location_id": string }; Returns: undefined
                           },
"undo_completion":
{ Args: { "p_service_record_id": string }; Returns: undefined
                           },
"update_tenant_settings":
{ Args: { "p_coverage_expiring_days"?: number,"p_currency_code": string,"p_date_format": string,"p_fiscal_year_start_month": number,"p_locale": string,"p_obligation_due_soon_days"?: number,"p_required_asset_fields": (string)[],"p_time_zone": string }; Returns: undefined
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
