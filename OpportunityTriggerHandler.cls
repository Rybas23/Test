/**
 * @description       : 
 * @author            : João Rosa
 * @group             : 
 * @last modified on  : 05-04-2023
 * @last modified by  : João Rosa
**/
public with sharing class OpportunityTriggerHandler
{	
    public static void handleBeforeInsertOpportunity(List<Opportunity> newOpps, Map<Id, Opportunity> oldOppsMap) {
        System.debug('RRR OpportunityTriggerHandler::handleBeforeInsertOpportunity');
        setIdentifier(newOpps);
        verifyStartDate(newOpps);
        setPrevisaoAluguer(newOpps, oldOppsMap);
        verifyEncomendasCanceladasAccount(newOpps);
        setOpportunityDefaultValues(newOpps);
        setOpportunityPricebook(newOpps);
        setAmountAndStatus(newOpps);
        updateZoneSeller(newOpps, oldOppsMap);
        updateSalesAssistant(newOpps, oldOppsMap);
    }      
    
    public static void handleBeforeUpdateOpportunity(List<Opportunity> newOpps, List<Opportunity> oldOpps, Map<Id, Opportunity> oldOppsMap) {
        System.debug('RRR OpportunityTriggerHandler::handleBeforeUpdateOpportunity');
        
        List<Opportunity> opportunityToCheckLineItems = new List<Opportunity>();
        
        for(Opportunity opp : newOpps) {
            Opportunity oldOpp = oldOppsMap.get(opp.Id);
            
            // Status Change
            if(opp.StageName != oldOpp.StageName) {
                if(opp.StageName == 'Geração de Contrato') {
                    opportunityToCheckLineItems.add(opp);
                }
            }
        }
        
        commercialValidation(newOpps);
        setPrevisaoAluguer(newOpps, oldOppsMap);
        changeOpportunityPricebook(newOpps, oldOppsMap);
        updateZoneSeller(newOpps, oldOppsMap);
        UpdateConLeasedEquipments(newOpps);
        naoReabrirProposta(newOpps, oldOppsMap);
        updateSalesAssistant(newOpps, oldOppsMap);
        opportunityStatus(newOpps, oldOppsMap);
        System.debug(opportunityToCheckLineItems);
        
        if(!opportunityToCheckLineItems.isEmpty()) {
            checkOpportunityLineItems(opportunityToCheckLineItems);
        }
    }
    
    public static void handleAfterInsertOpportunity(Map<Id, Opportunity> newOppsMap) {
        System.debug('RRR OpportunityTriggerHandler::handleAfterInsertOpportunity');
        createFollowUpTasks(newOppsMap);
        //  Ricardo Reis    -   03/04/2023  -   linha em baixo estava comentada, retirei comentario, repus 
        sendOpportunitiesAndOppLineItemsToInsphire(newOppsMap.values(), null); 
    }
    
    public static void handleAfterUpdateOpportunity(List<Opportunity> newOpps, Map<Id, Opportunity> oldOppsMap) {
        System.debug('RRR OpportunityTriggerHandler::handleAfterUpdateOpportunity');
        calcularValorTotalObra(newOpps, oldOppsMap);
        sendOpportunitiesAndOppLineItemsToInsphire(newOpps, oldOppsMap); 
        updateChildsDates(newOpps, oldOppsMap); 
        extractAccountsAndSendToPHC(newOpps, oldOppsMap); 
        updateExternalNotesQuote(newOpps, oldOppsMap);
        deleteContracts(newOpps, oldOppsMap);
        uploadFiles(newOpps,oldOppsMap);
    }

    public static void uploadFiles(List<Opportunity> newOpps, Map<Id, Opportunity> oldOppsMap){
        
        //iterar pelas opps
        //	se a opp cumpre a condição do stagename
        //		enviar os ficheiros todos associadas à opp
        //		
        System.debug('uploadFiles begin ');	
               
        Set<Id> oppIdSet = new Set<Id>();
        
        for(Opportunity newOpp : newOpps){
            
            if((newOpp.StageName != 'Nova' && newOpp.StageName != 'Em Tratamento') && ((oldOppsMap.get(newOpp.Id)).StageName == 'Nova' || (oldOppsMap.get(newOpp.Id)).StageName =='Em Tratamento')){
				System.debug('opp upload triggered: ' + newOpp.Id);	
                FTPWebServiceExample.uploadFiles(newOpp.Id, null);
				oppIdSet.add(newOpp.Id);         
            } 
		}
        
        System.debug('oppIdSet: ' + oppIdSet);	
        for(Lead newLead : [SELECT Id, Related_Opportunity__c FROM Lead WHERE Related_Opportunity__c IN :oppIdSet]){
            System.debug('newLead: ' + newLead);
            FTPWebServiceExample.uploadFiles(newLead.Id, null);
        }
	}
    
    private static void deleteContracts(List<Opportunity> newOpps, Map<Id, Opportunity> oldOppsMap){
        Id idOppToDelete = newOpps[0].Id;
        Opportunity oldOpp = oldOppsMap.get(idOppToDelete);
        if(newOpps[0].StageName == 'Negociação' && oldOpp.StageName == 'Adjudicado'){
            List<Contract> deleteContract = [Select id from Contract where id =: idOppToDelete];
            Database.delete(deleteContract);
        }
    }
    
    // Método que verifica se na criação de uma proposta, o field 'Start_Date__c' é vazio.
    // Caso seja vazio, o field é atualizado para a data atual.
    private static void verifyStartDate(List<Opportunity> newOpps) {
        Datetime dt;
        for (Opportunity newOpp : newOpps) {
            if (newOpp.Start_Date__c == null){newOpp.Start_Date__c = System.today();}            
            Date dueDate = newOpp.Data_de_Entrega__c;
            Date startDate = newOpp.Start_Date__c;
            Integer numberDaysDue = startDate.daysBetween(dueDate);
            system.debug(numberDaysDue);
            if(numberDaysDue > 7) {                 
                dt= Datetime.newInstance(newOpp.Data_de_Entrega__c -7, Time.newInstance(10, 0, 0, 0));                
            }
            else if (numberDaysDue <= 7) {          
                dt= Datetime.newInstance(newOpp.Start_Date__c +1, Time.newInstance(10, 0, 0, 0));                
            }
            Date myDate = date.newinstance(dt.year(), dt.month(), dt.day());
            newOpp.CloseDate = myDate;
        }
    }
    
    // Método que verifica se, ao criar uma proposta, o cliente associado tem encomendas canceladas. 
    public static void verifyEncomendasCanceladasAccount(List<Opportunity> newOpps) {
        EncomendasCanceladas__c mc = EncomendasCanceladas__c.getOrgDefaults();
        Boolean encomendasCanceladas = mc.Permitir_Leads_Encomendas_Canceladas__c;
        
        Set<Id> accountIds = new Set<Id>();
        for (Opportunity opp : newOpps) {
            accountIds.add(opp.AccountId);
        }
        
        Map<Id, Account> accounts = new Map<Id, Account>([
            SELECT Id, Encomendas_Canceladas__c
            FROM Account
            WHERE Id IN: accountIds
        ]);
        
        for (Opportunity opp : newOpps) {
            if (opp.AccountId != null && !accounts.isEmpty() && accounts.get(opp.AccountId).Encomendas_Canceladas__c && !encomendasCanceladas && !Test.isRunningTest()) {
                opp.addError('O cliente relacionado tem encomendas canceladas. Não é possível elaborar a proposta.');                
            }
        }
    }
    
    // Método que define diversos valores default para vários campos da Opportunity.
    public static void setOpportunityDefaultValues(List<Opportunity> newOpps) {
        for (Opportunity opp : newOpps) {
            opp.Billing_Start_Date__c = opp.Data_de_Entrega__c;
            opp.Hire_Deposit_Picklist__c = opp.Hire_Deposit__c;
        }
    }
    
    // Atribui o valor ao campo Previsão de Aluguer após:
    // - Inserção de uma nova Proposta; 
    // - Alteração da Data de Entrega e/ou Data de Retorno.
    public static void setPrevisaoAluguer(List<Opportunity> newOpps, Map<Id, Opportunity> oldOppsMap) {
        for (Opportunity newOpp : newOpps) {
            if (newOpp.Data_de_Entrega__c != null && newOpp.Estimated_Return_Date__c != null) {
                if (oldOppsMap == null) {
                    generatePrevisaoAluguer(newOpp);
                } else {
                    Opportunity oldOpp = oldOppsMap.get(newOpp.Id);
                    
                    if (newOpp.Estimated_Return_Date__c != oldOpp.Estimated_Return_Date__c || newOpp.Data_de_Entrega__c != oldOpp.Data_de_Entrega__c) {
                        generatePrevisaoAluguer(newOpp);
                    }
                }
            } else {
                newOpp.Duracao_Estimada_de_Aluguer__c = ''; // se alguma das datas for 'null', colocar previsão de aluguer vazio.
            }
        }
    }
    
    // Método auxiliar que gera a Previsão de Aluguer sob a forma de "X Meses e Y Dias" \ 
    // com base na data de início e retorno previstas.
    private static void generatePrevisaoAluguer(Opportunity opp) {
        Date data_de_entrega = opp.Data_de_Entrega__c;
        Date data_de_retorno = opp.Estimated_Return_Date__c;
        
        String previsao_de_aluguer = '';
        
        Integer totalDays = data_de_entrega.daysBetween(data_de_retorno) + 1;
        Integer months    = (Integer) math.floor(totalDays / 30);
        Integer days      = math.mod(totalDays, 30);
        
        if (totalDays > 30) {
            if (months == 1) {
                if (days == 1)
                    previsao_de_aluguer = months + ' Mês e ' + days + ' Dia';
                else
                    previsao_de_aluguer = months + ' Mês e ' + days + ' Dias';
            } else {
                if (days == 0)
                    previsao_de_aluguer = months + ' Meses';
                else if (days == 1)
                    previsao_de_aluguer = months + ' Meses e ' + days + ' Dia';
                else
                    previsao_de_aluguer = months + ' Meses e ' + days + ' Dias';
            }
        } else {
            if (totalDays == 1)
                previsao_de_aluguer = totalDays + ' Dia';
            else {
                previsao_de_aluguer = totalDays + ' Dias';   
            }
        }
        
        opp.Duracao_Estimada_de_Aluguer__c = previsao_de_aluguer;
    }
    
    /**
* Calcula o valor total da Obra baseado no 'Montante' de cada Proposta:
*  1) Caso seja adicionada uma Obra à Proposta, é necessário adicionar o total de 'Montante' à respetiva Obra
*  2) Caso seja removida uma Obra à Proposta, é necessário subtrair o total de 'Montante' à respetiva Obra
*  3) Caso o total de 'Montante' de uma Proposta diminua, subtrair a diferença ao valor total da Obra
*  4) Caso o total de 'Montante' de uma Proposta aumente, adicionar a diferença ao valor total da Obra
*/
    public static void calcularValorTotalObra(List<Opportunity> newOpps, Map<Id, Opportunity> oldOppsMap) {
        List<Obra__c> updatedObras = new List<Obra__c>();

        //  Ricardo Reis    -   10/04/2023  -   Alterado metodo para não fazer query dentro do for

        Set<string> sObras = new Set<string>();
        for (Opportunity newOpp : newOpps)
        {
            Opportunity oldOpp = oldOppsMap.get(newOpp.Id);
            
            if (newOpp.Amount != null && oldOpp.Amount != null) 
            {
                if (oldOpp.Obra__c != null) 
                {
                    sObras.add(oldOpp.Obra__c);
                }
            }
        }
        
        Map<Id, Obra__c> mObras = new Map<Id, Obra__c>([SELECT Id, Valor__c FROM Obra__c WHERE Id IN :sObras]);

        for (Opportunity newOpp : newOpps) {
            Opportunity oldOpp = oldOppsMap.get(newOpp.Id);
            
            if (newOpp.Amount != null && oldOpp.Amount != null) {
                if (oldOpp.Obra__c != null) {
                    Obra__c obra = mObras.get(oldOpp.Obra__c);
                    /*
                    Obra__c obra = [
                        SELECT Id, Valor__c
                        FROM Obra__c
                        WHERE Id =: oldOpp.Obra__c
                    ];
                    */
                    
                    if (newOpp.Obra__c != null) {
                        if (newOpp.Amount != oldOpp.Amount) {
                            if (newOpp.Amount > oldOpp.Amount) {
                                obra.Valor__c += (newOpp.Amount - oldOpp.Amount);
                            } else {
                                Double valor = obra.Valor__c - (oldOpp.Amount - newOpp.Amount);
                                if (valor < 0)
                                    obra.Valor__c = 0;
                                else
                                    obra.Valor__c = valor;
                            }
                        }
                    } else {
                        Double valor = obra.Valor__c - newOpp.Amount;
                        if (valor < 0)
                            obra.Valor__c = 0;
                        else
                            obra.Valor__c = valor;
                    }
                    
                    updatedObras.add(obra);
                } else {
                    if (newOpp.Obra__c != null) {
                        /*
                        Obra__c obra = [
                            SELECT Id, Valor__c
                            FROM Obra__c
                            WHERE Id =: newOpp.Obra__c
                        ];
                        */
                        Obra__c obra = mObras.get(newOpp.Obra__c);
                        obra.Valor__c += newOpp.Amount;
                        
                        updatedObras.add(obra);
                    }
                }
            }
        }
        
        if (updatedObras.size() > 0) {
            try {
                update updatedObras;
            } catch (DMLException e) { Utils.createLogError('Opportunity', 'OpportunityTriggerHandler', 'calcularValorTotalObra', 'The following exception occurred: ' + e.getMessage(), '', ''); }
        }
    }
    
    /**
* Método que trata de enviar (para a classe utils) os dados necessários para efetuar a comunicação Insphire.
* Esta comunicação tem como objetivo a criação/edição de Propostas e criação de OppLineItems do lado do Insphire.
* 
* NOTAS: 
*  - Neste método são manipulados Opportunities e respetivos INSERTS de Opportunity Line Items
*  - Se a proposta for fechada (Perdido/Anulada), então deve ser enviada para Insphire.
*  - Se proposta estiver num estado diferente de 'Verificação de Crédito e Equipamentos' não há qualquer tratamento, 
*  porque a partir deste estado, o Contrato é a entidade principal.
*/
    public static void sendOpportunitiesAndOppLineItemsToInsphire(List<Opportunity> newOpps, Map<Id, Opportunity> oldOppsMap) {
        if (CheckRecursive.firstcall) {
            CheckRecursive.firstcall = false; // controlar recursividade de triggers.
            
            Set<Id> oppsToCreateInsphire = new Set<Id>();
            Set<Id> oppsToUpdateInsphire = new Set<Id>();
            Set<Id> closedOppLineItemsToUpdateInsphire = new Set<Id>();
            //  Ricardo Reis    -   27/03/2023
            Set<Id> cancelledOppsToUpdateInsphire = new Set<Id>();
            
            for (Opportunity opp : newOpps) 
            {
                if (  (opp.StageName == 'Negociação') || (opp.StageName == 'Verificação de Crédito e Equipamentos') || (opp.StageName == 'Perdido' || opp.StageName == 'Anulada') ) 
                {
                    //  Ricardo Reis    -   29/03/2023
                    if(oldOppsMap == null && opp.RecID__c == null)
                    {
                        oppsToCreateInsphire.add(opp.Id); // insert opportunities.
                        continue;
                    }
                    else if ((opp.StageName != oldOppsMap.get(opp.Id).StageName) && (opp.StageName == 'Negociação') && (oldOppsMap.get(opp.Id).StageName != 'Perdido' && oldOppsMap.get(opp.Id).StageName != 'Anulada' )) {
                        if(opp.RecID__c == null){
                            oppsToCreateInsphire.add(opp.Id); // insert opportunities.
                        }
                    } else if(opp.RecID__c == oldOppsMap.get(opp.Id).RecID__c) { //Necessário If para verificar se é a primeira atualização do RecID.
                        oppsToUpdateInsphire.add(opp.Id); // update opportunties.
                    }
                    
                    // Para atualizar os produtos da proposta quando a proposta é anulada || atualizar os produtos da proposta quando a proposta é reaberta.
                    if ( (opp.StageName == 'Perdido' || opp.StageName == 'Anulada') || (opp.StageName != oldOppsMap.get(opp.Id).StageName) && (oldOppsMap.get(opp.Id).StageName == 'Perdido' || oldOppsMap.get(opp.Id).StageName == 'Anulada') ) {
                        closedOppLineItemsToUpdateInsphire.add(opp.Id);
                    }
                    if(opp.AccountID != oldOppsMap.get(opp.Id).AccountId)
                        closedOppLineItemsToUpdateInsphire.add(opp.Id);
                    if ( (opp.StageName == 'Perdido' || opp.StageName == 'Anulada') && (opp.StageName != oldOppsMap.get(opp.Id).StageName)) {
                        cancelledOppsToUpdateInsphire.add(opp.Id);
                    }
                }
                else if(oldOppsMap != null && opp.StageName == 'Em Tratamento' && oldOppsMap.get(opp.Id).StageName == 'Adjudicado')
                {
                    oppsToUpdateInsphire.add(opp.Id);
                }
            }
            
            // OppLineItems que foram criados associados às Opportunities.
            Map<Id, OpportunityLineItem> oppLineItemsToCreateInsphire = new Map<Id, OpportunityLineItem>();
            if(!oppsToCreateInsphire.isEmpty())
            {
                oppLineItemsToCreateInsphire = new Map<Id, OpportunityLineItem>(
                [
                    SELECT Id, OpportunityId
                    FROM OpportunityLineItem 
                    WHERE 
                    RecID__c = NULL AND
                    OpportunityId IN :oppsToCreateInsphire
                ]);
            }
            
            // OppLineItems que foram criados associados às Opportunities.
            Map<Id, OpportunityLineItem> closedOppLineItemsToUpdateInsphireMap = new Map<Id, OpportunityLineItem>();
            if(!closedOppLineItemsToUpdateInsphire.isEmpty())
            {
                closedOppLineItemsToUpdateInsphireMap = new Map<Id, OpportunityLineItem>([
                    SELECT Id, OpportunityId
                    FROM OpportunityLineItem 
                    WHERE OpportunityId IN :closedOppLineItemsToUpdateInsphire
                ]);
            }
            
            if (oppsToCreateInsphire.size() > 0 && !Test.isRunningTest()) {
                Utils.prepareAndSendOpportunitiesToInsphire(oppsToCreateInsphire, 'insert');
                
                if (!oppLineItemsToCreateInsphire.isEmpty()) {
                    Utils.prepareAndSendOppLineItemsToInsphire(oppLineItemsToCreateInsphire.keySet(), 'insert');
                    Utils.prepareAndSendContnoteOppToInsphire(oppsToCreateInsphire, 'Created Hire Estimate', 'The Hire Estimate was first created');
                }
            }
            
            if (oppsToUpdateInsphire.size() > 0) {
                System.debug('Insert de novos itens após estar em Negociação');
                
                if(!Test.isRunningTest()) {
                    Utils.prepareAndSendOpportunitiesToInsphire(oppsToUpdateInsphire, 'update'); 
                }
                
                /**
* Comentado no dia 04/03/2022 (dd/MM/yyyy) por conta da incidencia ID.12
* Havia um cenario especifico em que se chamava a integração para criar
* ContItens no banco do Insphire duas vezes. 
* 
* Esse cenario era quando a proposta passava para Negociação e a proposta sofria 
* um UPDATE antes das OpportuniLineItems terem a resposta do Insphire para preencher
* o campo RecID__c
* 
* Assim que o negocio testar remover essas linhas para não guardar codigo que nao se usa
*
// Adicionado para enviar items ao atualizar a proposta em negociação
Map<Id, OpportunityLineItem> oppLineItemsToCreateInsphireMap = new Map<Id, OpportunityLineItem>([
SELECT Id, OpportunityId
FROM OpportunityLineItem 
WHERE OpportunityId IN :oppsToUpdateInsphire AND RecID__c = ''
]);
if (!oppLineItemsToCreateInsphireMap.isEmpty()) {
if(!Test.isRunningTest()) {
Utils.prepareAndSendOppLineItemsToInsphire(oppLineItemsToCreateInsphireMap.keySet(), 'insert');
}
}
*/
            }
            
            if(!closedOppLineItemsToUpdateInsphireMap.isEmpty()) {
                if(!Test.isRunningTest()) {
                    Utils.prepareAndSendOppLineItemsToInsphire(closedOppLineItemsToUpdateInsphireMap.keySet(), 'update');

                }
            }
            if(!cancelledOppsToUpdateInsphire.isEmpty())
            {
                System.debug('RRR ContNote');
                String uniqueId = Utils.newGUID();
    
                System.schedule(
                    'InsphireVendapCalloutsBatch-createContnoteCancelled-' + uniqueId + ': ' + String.valueOf(Datetime.now()),
                    Utils.generateNexFireTime(0,2,0),
                    new InsphireVendapCalloutsBatch(cancelledOppsToUpdateInsphire, 'contnote;Canceled', uniqueId)
                );
            }
        }
    }
    
    // Método que preenche o valor do Pricebook associado à Opportunity \
    // baseado no valor do field 'Type' que foi escolhido aquando a criação.
    // 
    // (Opportunity.Type = 'Eventos')                => Pricebook: 'Eventos' ;
    // (Opportunity.Type = 'Construção e Indústria') => Pricebook: 'Construção e Indústria' ;
    // (Opportunity.Type = 'Concursos Públicos')     => Pricebook: 'Construção e Indústria' ;
    private static void setOpportunityPricebook(List<Opportunity> newOpps) {
        // Obter todos os pricebooks e organizar a informação num Map.
        // O nome do Pricebook é usado como chave no Map.
        Map<String, Id> pbks = new Map<String, Id>();
        for (Pricebook2 pb : [SELECT Id, Name FROM Pricebook2]) {
            String key = 'Standard'; // by default, usamos Standard Price Book.
            
            switch on pb.Name {
                when 'Construção e Indústria'   { key = 'ConstrucaoIndustria'; }
                when 'Entidades e Organizações' { key = 'EntidadesOrganizacoes'; }
                when 'Eventos'                  { key = 'Eventos'; }      
            }
            
            pbks.put(key, pb.Id);
        }
        
        Set<Id> idAccounts = new Set<Id>();
        for (Opportunity newOpp : newOpps) {
            idAccounts.add(newOpp.AccountId);
        }
        Map<Id, Account> mapAccounts = new Map<Id, Account>([SELECT Id, Segment__c FROM Account WHERE Id IN: idAccounts]);
        
        for (Opportunity opp : newOpps) {
            // Se o tipo de proposta for 'ConcursosPublicos', \ 
            // o Pricebook assumido será o de 'ConstrucaoIndustria'.
            if (opp.Type == 'ConcursosPublicos') {
                String segment = mapAccounts.get(opp.AccountId).Segment__c;
                
                if (segment != null && segment.contains('Eventos')) {
                    opp.Pricebook2Id = pbks.get('Eventos');    
                } else if (segment != null && segment.contains('EOP')) {
                    opp.Pricebook2Id = pbks.get('EntidadesOrganizacoes');
                } else {
                    opp.Pricebook2Id = pbks.get('ConstrucaoIndustria');
                }
            } else {
                opp.Pricebook2Id = pbks.get(opp.Type);
            }
        }
    }
    
    // Método que altera o Pricebook associado à Opportunity.
    // Esta alteração só ocorre se o field 'Type' for alterado.
    private static void changeOpportunityPricebook(List<Opportunity> newOpps, Map<Id, Opportunity> oldOppsMap) {
        // Obter todos os pricebooks e organizar a informação num Map.
        // O nome do Pricebook é usado como chave no Map.
        Map<String, Id> pbks = new Map<String, Id>();
        boolean isChanged = false;
        
        // Verifica se houve alteração de Type.
        for (Opportunity newOpp : newOpps) {
            Opportunity oldOpp = oldOppsMap.get(newOpp.Id);            
            if (newOpp.Type != oldOpp.Type) {
                isChanged = true;
            }
        }
        
        if (isChanged) {
            for (Pricebook2 pb : [SELECT Id, Name FROM Pricebook2]) {
                String key = 'Standard'; // by default, usamos Standard Price Book.
                
                switch on pb.Name {
                    when 'Construção e Indústria'   { key = 'ConstrucaoIndustria'; }
                    when 'Entidades e Organizações' { key = 'EntidadesOrganizacoes'; }
                    when 'Eventos'                  { key = 'Eventos'; }      
                }
                
                pbks.put(key, pb.Id);
            }
            
            Set<Id> idAccounts = new Set<Id>();
            for (Opportunity newOpp : newOpps) {
                idAccounts.add(newOpp.AccountId);
            }
            Map<Id, Account> mapAccounts = new Map<Id, Account>([SELECT Id, Segment__c FROM Account WHERE Id IN: idAccounts]);
            
            // Iterar as novas Opportunity e verificar se houve mudança do field 'Type'.
            for (Opportunity newOpp : newOpps) {
                Opportunity oldOpp = oldOppsMap.get(newOpp.Id);
                
                if (newOpp.Type != oldOpp.Type) {
                    // Se o tipo de proposta for 'ConcursosPublicos', \ 
                    // o Pricebook assumido será o de 'ConstrucaoIndustria'.
                    if (newOpp.Type == 'ConcursosPublicos') {
                        String segment = mapAccounts.get(newOpp.AccountId).Segment__c;
                        if (segment != null && segment.contains('Eventos')) {
                            newOpp.Pricebook2Id = pbks.get('Eventos');    
                        } else if (segment != null && segment.contains('EOP')) {
                            newOpp.Pricebook2Id = pbks.get('EntidadesOrganizacoes');
                        } else {
                            newOpp.Pricebook2Id = pbks.get('ConstrucaoIndustria');
                        }
                    } else {
                        newOpp.Pricebook2Id = pbks.get(newOpp.Type);
                    }
                }
            }   
        }
    }
    
    // Método que cria o identificador para a Proposta.
    // Se este não existir (porque não veio a partir de uma Lead), o cálculo passa por \
    // obter todas as Propostas atuais, ordenadas por ordem decrescente do Identificador,
    // somar +1 ao Identificador maior, e colocar esse novo Identificador na nova Proposta.
    public static void setIdentifier(List<Opportunity> newOpps) {
        IdentifierSettings__c ident = IdentifierSettings__c.getOrgDefaults();
        Set<String> idLeads = new Set<String>();
        Map<Id,Lead> mapLeads;
        Integer newIdentifier;
        Integer biggestContractIdentifier = 00;
        Integer biggestIdentifier = 00;
        Boolean isChild = false;

        for (Opportunity op : newOpps) {
            if (op.Lead_Id__c != null) idLeads.add(op.Lead_Id__c);
            if (op.Parent_Proposal__c != null) {
                isChild = true;
                Opportunity parentOpp = [SELECT Id, Identifier__c FROM Opportunity WHERE Id =: op.Parent_Proposal__c ];
                List<Opportunity> childOpps = [SELECT Id, Identifier__c FROM Opportunity WHERE Parent_Proposal__c =: parentOpp.Id];
                List<Contract> childContracts = [SELECT Id, Identifier__c FROM Contract WHERE SBQQ__Opportunity__c =: parentOpp.Id];
                if (childOpps.size() > 0 ) {
                    for (Opportunity childOpp : childOpps) {
                        if (biggestIdentifier < Integer.valueOf(childOpp.Identifier__c.right(2))) {
                            biggestIdentifier = Integer.valueOf(childOpp.Identifier__c.right(2));
                        }
                    }
                }
                if (childContracts.size() > 0 ) {
                    biggestIdentifier += childContracts.size();
                }
                biggestIdentifier++;
                op.Identifier__c = parentOpp.Identifier__c + 'EL' + String.valueOf(biggestIdentifier).leftPad(2, '0');
                System.debug('Child Opportunity Identifier: ' + op.Identifier__c);
            }
        }
        
        if (!isChild) {
            if (!idLeads.isEmpty()) {
                mapLeads = new Map<Id,Lead>([SELECT Id, Identifier__c FROM Lead WHERE Id IN: idLeads]);
                for (Opportunity op : newOpps) {
                    newIdentifier = Integer.valueOf(mapLeads.get(op.Lead_Id__c).Identifier__c.substringAfter('-'));
                    op.Identifier__c = 'P-'+String.valueOf(newIdentifier).leftPad(10, '0');
                }
            } else {
                newIdentifier = Integer.valueOf(ident.Identifier__c);
                
                for (Opportunity op : newOpps) {
                    newIdentifier = newIdentifier + 1;
                    op.Identifier__c = 'P-'+String.valueOf(newIdentifier).leftPad(10, '0');
                }
                
                ident.Identifier__c = String.valueOf(newIdentifier).leftPad(10, '0');
                update ident;
            }
            System.debug('Identifier --> '+ String.valueOf(newIdentifier).leftPad(10, '0'));
        }
        
    }
    
    // ...
    public static void setAmountAndStatus(List<Opportunity> newOpps) {
        for (Opportunity op : newOpps) {
            if (op.isClone()) {
                op.Amount = 0;
                op.StageName = 'Nova';
            }
        }
    }
    
    // ...
    public static void updateZoneSeller(List<Opportunity> newOpps, Map<Id, Opportunity> oldOppsMap) {
        list<County__c> countyList = new list<County__c>();
        Map<Id, String> countyOppMap = new Map<Id, String>();
        
        List<Opportunity> oppsToUpdateWithDistrict = new List<Opportunity>();
        
        // Creating a variable that will receive a list of CountyID.
        Set<Id> countyIdOppList = new Set<Id>();  
        boolean isChanged = false;
        
        // Verifica se houve alteração de Type.
        if (!Trigger.isInsert) {
            for (Opportunity newOpp : newOpps) { // Quando for insert o get retorna null porque nao existe nenhum valor. 
                Opportunity oldOpp = oldOppsMap.get(newOpp.Id);            
                if (newOpp.Localidade__c != oldOpp.Localidade__c) {
                    isChanged = true;
                }
            } 
        } else {
            isChanged = true;
        }
        
        if (isChanged) {
            // Receiving a list of County
            for (Opportunity opp : newOpps) {
                if (opp.Localidade__c != null) {
                    if(opp.Type == 'ConstrucaoIndustria'){
                        countyIdOppList.add(Opp.County__c);
                    } else {
                        oppsToUpdateWithDistrict.add(opp);
                    }
                    opp.Hire_Deposit_Picklist__c = opp.Hire_Deposit__c;  
                }
            }
            
            if(countyIdOppList.isEmpty() && oppsToUpdateWithDistrict.isEmpty()) {
                return;
            }
            
            // Buscas os usuarios da ZoneSeller, tanto a nivel de Distrito quanto Municipios
            List<User> userList = [
                SELECT Id, County__c, District__c
                FROM User
                WHERE County__c != null OR District__c != null
                ORDER BY Name
            ];
            
            List<User> countyUserList = new List<User>();
            List<User> districtUserList = new List<User>();
            
            for(User user : userList) {
                if(user.County__c != null) {
                    countyUserList.add(user);
                }
                
                if(user.District__c != null) {
                    districtUserList.add(user);
                }
            }
            
            if (!countyIdOppList.isEmpty()) {
                countyList = [SELECT Id, Name FROM County__c WHERE Id in : countyIdOppList];
                for (County__c ctlist : countyList) { 
                    countyOppMap.put(ctlist.Id, ctlist.Name);
                }
            }
            
            if (!countyOppMap.isEmpty()) {
                if (!countyUserList.isEmpty()) {
                    // Creating a MAP.
                    Map<String, Id> userMapCounty = new Map<String, Id>();
                    
                    // As the County field in User is a multi-picklist, it is necessary to separate the values per line. 
                    for(User user : countyUserList) {
                        String countyField = user.County__c;
                        List<String> countyFieldList = new List<String>(countyField.split(';'));
                        
                        for(String county : countyFieldList) {
                            userMapCounty.put(county, user.Id);
                        } 
                    }   
                    
                    // Cycle through the accounts assigning the correct value for the field.
                    for (Opportunity opp : newOpps) {
                        if (opp.Localidade__c != null) {
                            if(opp.Zone_Seller__c == null){
                                System.debug('Zone Seller : ' + countyOppMap.get(opp.County__c));
                                opp.Zone_Seller__c = userMapCounty.get(countyOppMap.get(opp.County__c));
                            }
                        } 
                    }
                }
            }
            
            if(!districtUserList.isEmpty() && !oppsToUpdateWithDistrict.isEmpty()) {
                updateZoneSellerUsingDistrict(oppsToUpdateWithDistrict, districtUserList);
            }
        }
    }
    
    private static void updateZoneSellerUsingDistrict(List<Opportunity> opportunityList, List<User> userList) {
        Set<Id> localidadeIds = new Set<Id>();
        Map<String, Id> userIdByDistrictName = new Map<String, Id>();
        
        for(Opportunity opp : opportunityList) {
            if(opp.Localidade__c != null) {
                localidadeIds.add(opp.Localidade__c);
            }
        }
        
        Map<Id, Localidade__c> localidadesById = new Map<Id, Localidade__c>(
            [
                SELECT Id, Name, District__c, District__r.Name
                FROM Localidade__c
                WHERE Id IN :localidadeIds
            ]
        );
        
        // District field is a multi-picklist, it is necessary to separate the values per line. 
        for(User user : userList) {
            String districtField = user.District__c;
            List<String> districtList = new List<String>(districtField.split(';'));
            
            for(String district : districtList) {
                userIdByDistrictName.put(district, user.Id);
            } 
        }
        
        // Update Opportunity
        for(Opportunity opp : opportunityList) {
            
            if(opp.Localidade__c == null /*|| opp.Zone_Seller__c != null*/ ) {
                continue;
            }
            
            Localidade__c oppLocalidade = localidadesById.get(opp.Localidade__c);
            Id districtUserId = userIdByDistrictName.get(oppLocalidade.District__r.Name);
            opp.Zone_Seller__c = districtUserId;
        }
    }
    
    // ...
    public static void UpdateConLeasedEquipments(List<Opportunity> newOpps) {
        Set<String> idContact = new Set<String>();
        if (!newOpps.isEmpty()) {
            for (Opportunity opp : newOpps) {
                if (opp.StageName == 'Adjudicado' && opp.Pessoa_de_contacto__c != null) {
                    idContact.add(opp.Pessoa_de_Contacto__c);
                }
            }
        }
        
        if (!idContact.isEmpty()) {
            List<Contact> listContact = new List<Contact>([SELECT Id, Pull_to_Pardot__c FROM Contact WHERE Id in :idContact]);
            if (!listContact.isEmpty()) {
                for (Opportunity opp : newOpps) {
                    for (Contact con : listContact) {              
                        con.Pull_to_Pardot__c = !con.Pull_to_Pardot__c;                        
                    }
                }
                
                update listContact;
            }
        }    
    }
    
    // ...
    public static void updateChildsDates(List<Opportunity> newOpps, Map<Id, Opportunity> oldOppsMap) {
        Map<Id,SBQQ__Quote__c> oppQuotes = new Map<Id,SBQQ__Quote__c>();
        List<SBQQ__Quote__c> quotesToUpdate = new List<SBQQ__Quote__c>();
        List<SBQQ__Quote__c> getQuotesToUpdate = new List<SBQQ__Quote__c>();
        List<SBQQ__QuoteLine__c> getQuoteLinesToUpdate = new List<SBQQ__QuoteLine__c>();
        List<SBQQ__QuoteLine__c> quoteLinesToMap = new List<SBQQ__QuoteLine__c>();
        Map<Id,List<SBQQ__QuoteLine__c>> quoteLines = new Map<Id,List<SBQQ__QuoteLine__c>>();
        List<SBQQ__QuoteLine__c> quoteLinesToUpdate = new List<SBQQ__QuoteLine__c>();
        Boolean dataChange = false;
        
        // Testa para verificar se ha alteraçoes nas datas.
        for (Opportunity opp : newOpps) {
            if (opp.Data_de_Entrega__c !=  oldOppsMap.get(opp.id).Data_de_Entrega__c || opp.Estimated_Return_Date__c != oldOppsMap.get(opp.id).Estimated_Return_Date__c) {
                dataChange = true;
            }
        }
        
        if (dataChange) {
            if (!newOpps.isEmpty()) {
                getQuotesToUpdate = [
                    SELECT id, SBQQ__StartDate__c, Estimated_Return_Date__c, SBQQ__Opportunity2__c 
                    FROM SBQQ__Quote__c 
                    WHERE SBQQ__Primary__c = true AND SBQQ__Opportunity2__c IN :newOpps
                ];
            }
        }
        
        if (dataChange) {
            if (!newOpps.isEmpty()) {
                for (Opportunity opp : newOpps) { 
                    for (SBQQ__Quote__c qt : getQuotesToUpdate) {
                        if (opp.SBQQ__PrimaryQuote__c != Null && qt.SBQQ__Opportunity2__c == opp.Id) {
                            // Guardar num Map o id da opportunidade(keyMap) e as quotes da opportunidade (MapValues).
                            oppQuotes.put(opp.Id, qt);    
                        }
                    }
                }
            }
            
            if (!newOpps.isEmpty() && !oldOppsMap.isEmpty() && !oppQuotes.isEmpty()) {
                for (Opportunity opp : newOpps) {
                    // Atualiza as datas da quote com base nas datas da Proposta.
                    oppQuotes.get(opp.Id).SBQQ__StartDate__c = opp.Data_de_Entrega__c;
                    oppQuotes.get(opp.Id).Estimated_Return_Date__c = opp.Estimated_Return_Date__c;
                    quotesToUpdate.add(oppQuotes.get(opp.Id));
                }
            }
            
            if (!quotesToUpdate.isEmpty()) {
                update quotesToUpdate;
                List<Id> quoteIdsList = new List<Id>();
                for(SBQQ__Quote__c qt : quotesToUpdate){
                    quoteIdsList.add(qt.id);
                }
                getQuoteLinesToUpdate = [
                    SELECT id, Estimated_Delivery_Date__c, Estimated_Return_Date__c, SBQQ__Quote__c 
                    FROM SBQQ__QuoteLine__c
                    WHERE SBQQ__Quote__c IN :quoteIdsList
                ];
            }
            
            if (!quotesToUpdate.isEmpty()) {
                for (SBQQ__Quote__c qt : quotesToUpdate) {
                    // Meter quoteLinesToMap vazio quando troca de quote.
                    quoteLinesToMap.clear();
                    for (SBQQ__QuoteLine__c ql : getQuoteLinesToUpdate) {
                        if (ql.SBQQ__Quote__c == qt.id) {
                            quoteLinesToMap.add(ql);
                        }
                    }
                    
                    // Guardar num Map o id da quote(keyMap) e as quoteslines da quote (MapValues).
                    quoteLines.put(qt.id, quoteLinesToMap);
                }
            }
            
            if (!quotesToUpdate.isEmpty() && !quoteLines.isEmpty()) {
                for (SBQQ__Quote__c qt : quotesToUpdate) {
                    for (SBQQ__QuoteLine__c ql : quoteLines.get(qt.id)) {
                        // Atualiza as datas da quoteline com base nas datas da quote.
                        ql.Estimated_Delivery_Date__c = qt.SBQQ__StartDate__c;
                        ql.Estimated_Return_Date__c = qt.Estimated_Return_Date__c;
                        quoteLinesToUpdate.add(ql); 
                    } 
                }
            }
            
            if (!quoteLinesToUpdate.isEmpty()) {
                update quoteLinesToUpdate;
            }
        }
    }
    
    // Método que extrai os IDs de todas as contas presentes nos contratos recém criados.
    // Posto isto, é invocado o método da classe 'Utils' que prepara todas as Accounts para serem enviadas e criadas no PHC.
    private static void extractAccountsAndSendToPHC(List<Opportunity> newOpps, Map<Id, Opportunity> oldOppsMap) {
        // Obter os IDs das Accounts e filtrar todos através de um Set<Id>.
        Set<Id> idAccounts = new Set<Id>();
        for (Opportunity opp : newOpps) {
            if (opp.StageName == 'Verificação de Crédito e Equipamentos' && opp.StageName != oldOppsMap.get(opp.Id).StageName)
                idAccounts.add(opp.AccountId);
        }
        
        // Enviar lista de Accounts para o PHC.
        if (!Test.isRunningTest() && idAccounts.size() > 0)
            Utils.prepareAndSendAccountsToPHC(idAccounts, 'insert');
    }
    
    // Método que após a criação de uma nova Proposta, insere uma Task associada a essa mesma Proposta.
    // Esta Task diz respeito ao Follow Up da Proposta para um determinado cliente.
    private static void createFollowUpTasks(Map<Id, Opportunity> newOppsMap) {
        Map<Id, Opportunity> oppsWithAccountName = new Map<Id, Opportunity>([
            SELECT Id, Identifier__c, Account.Name, CloseDate, Data_de_Entrega__c, Start_Date__c
            FROM Opportunity
            WHERE Id IN :newOppsMap.keySet()
        ]);
        
        // Lista de Tasks a serem inseridas no sistema.
        // O rimender set da task será de acordo com a data de inicio e a data de entrega.
        List<Task> followUpTasks = new List<Task>();
        
        for (Opportunity opp : oppsWithAccountName.values()) {           
            Task t = new Task(
                WhatId = opp.Id,
                Status = 'Active',
                Subject = 'Tarefa de Follow Up da Proposta \'' + opp.Identifier__c + '\' do Cliente \'' + opp.Account.Name + '\'',
                ActivityDate = opp.CloseDate,
                IsReminderSet = true,
                ReminderDateTime = opp.CloseDate,
                Type = 'Other'
            ) ;            
            followUpTasks.add(t);
        }
        
        if (followUpTasks.size() > 0)
            insert followUpTasks;
    }
    
    // ...
    public static void naoReabrirProposta(List<Opportunity> newOppsList, Map<Id, Opportunity> oldOppsMap) {
        List<RecordType> idRecType = new List<RecordType>();
        for (Opportunity newOpp : newOppsList) {
            Opportunity oldOpp = oldOppsMap.get(newOpp.id);
            system.debug('ANLN --------' + newOpp.StageName);
            system.debug('ANLN --------' + newOpp.tem_contratos__c);
            String stringId = String.valueOf(newOpp.Id);
            if (newOpp.StageName != oldOpp.StageName) {
                if ( (oldOpp.StageName == 'Perdido' || oldOpp.StageName == 'Anulada') && newOpp.StageName != 'Negociação' ) {                  
                    newOpp.addError('A proposta Só pode ser reaberta para negociação se for anulada ou perdida');
                } else if ( (oldOpp.StageName == 'Perdido' || oldOpp.StageName == 'Anulada') && newOpp.StageName == 'Negociação' ) {
                    idRecType = [select Id from RecordType where Name = 'Aluguer Vendap Edição' and SobjectType = 'Opportunity' LIMIT 1];
                    if (!idRecType.isEmpty()) {
                        newOpp.RecordTypeId = idRecType[0].id;
                        newOpp.Loss_Reason__c = '';
                        newOpp.Reopened__c = true;
                    }
                }
            }
        }
    }
    
    // ...
    public static void commercialValidation(List<Opportunity> newOppsList) {
        for (Opportunity newOpp : newOppsList) {
            if (newOpp.StageName == 'Em Tratamento' || newOpp.StageName == 'Negociação') {
                OppCreditValidationController.commercialValidation(newOpp);
            }
        }
    }
    
    public static void opportunityStatus(List<Opportunity> newOppsList, Map<Id, Opportunity> oldOppsMap) {
        //Map de Contractos associados a Opp.
        Map<Id, Contract> mapContract = new Map<Id, Contract>([SELECT Id, SBQQ__Opportunity__c FROM Contract WHERE SBQQ__Opportunity__c IN :newOppsList]);
        Map<Id, SBQQ__Subscription__c> mapSubs = new Map<Id, SBQQ__Subscription__c>([SELECT Id, SBQQ__Contract__c,SBQQ__Contract__r.SBQQ__Opportunity__c, Item_Status__c FROM SBQQ__Subscription__c WHERE SBQQ__Contract__c IN :mapContract.keySet()]);
        Map<Id, Integer> mapOppHired = new Map<Id, Integer>();
        List<Id> listOppId =new List<Id>();
        
        for(SBQQ__Subscription__c sub : mapSubs.values()){   
            if(mapOppHired.keySet().contains(sub.SBQQ__Contract__r.SBQQ__Opportunity__c)){
                if(sub.Item_Status__c == '1'){
                    Integer counter = mapOppHired.get(sub.SBQQ__Contract__r.SBQQ__Opportunity__c) + 1;
                    mapOppHired.put(sub.SBQQ__Contract__r.SBQQ__Opportunity__c, counter);
                }
            }else{
                if(sub.Item_Status__c == '1'){
                    mapOppHired.put(sub.SBQQ__Contract__r.SBQQ__Opportunity__c, 1);
                }else{
                    mapOppHired.put(sub.SBQQ__Contract__r.SBQQ__Opportunity__c, 0);
                }
            }
        }
        
        for (Opportunity newOpp :newOppsList) {
            Opportunity oldOpp = oldOppsMap.get(newOpp.id);
            if(oldOpp.StageName == 'Adjudicado' && newOpp.StageName == 'Negociação' && mapOppHired.get(newOpp.id)>0){
                newOpp.addError('Não é possível mudar para o estado Negociação porque existem equipamentos no estado Hire.');
                
            }else if(oldOpp.StageName == 'Adjudicado' && newOpp.StageName == 'Negociação' && mapOppHired.get(newOpp.id)==0){
                listOppId.add(newOpp.id);      
            }
            
        }
        
        if(!listOppId.isempty()) {
            deleteContract(listOppId);
        }   
        
    } 
    
    //Método que apaga todos os contratos associados à oportunidade que passou de Adjudicado para Negociação. Status da subscription diferente de 1(Hire).
    public static void deleteContract(List<Id> listIds) {
        
        List<Contract> listContract=[SELECT Id, SBQQ__Opportunity__c FROM Contract WHERE SBQQ__Opportunity__c IN :listIds];
        if(!listContract.isempty()){
            delete listContract;
        }
        
    }  
    
    // Método que preenche o campo 'Sales_Assistant__c' caso o campo 'Canvasser__c' seja preenchido ou alterado.
    public static void updateSalesAssistant(List<Opportunity> newOppsList, Map<Id, Opportunity> oldOppsMap) {
        Set<Id> idCanvassers = new Set<Id>();
        for (Opportunity newOpp : newOppsList) {
            if (Trigger.isInsert) {
                if (newOpp.Canvasser__c != null) {
                    idCanvassers.add(newOpp.Canvasser__c);
                }
            } else if (Trigger.isUpdate) {
                Opportunity oldOpp = oldOppsMap.get(newOpp.Id);
                if (newOpp.Canvasser__c != oldOpp.Canvasser__c && newOpp.Canvasser__c != null) {
                    idCanvassers.add(newOpp.Canvasser__c);
                }
            }
        }
        
        if(idCanvassers.size() != 0){
            
            // Obter o valor de Sales Assistant associado ao Canvasser da Proposta \
            // e extrair os valores API dos 'Sales_Assistant_IH__c'.
            Map<Id, User> canvasserSalesAssistantCodes = new Map<Id, User>([
                SELECT Id, Sales_Assistant_IH__c, Sales_Assistant_Code__c
                FROM User
                WHERE Id IN :idCanvassers
            ]);
            Set<Decimal> salesAssistantsCodesSet = new Set<Decimal>();
            for (User u : canvasserSalesAssistantCodes.values()) {
                if (u.Sales_Assistant_IH__c != null) {
                    salesAssistantsCodesSet.add(Decimal.valueOf(u.Sales_Assistant_IH__c));
                }
            }
            
            // Obter mapeamento entre o código do Sales Assistant e o seu ID em Salesforce.
            Map<Decimal, Id> code_salesAssistant = new Map<Decimal, Id>();
            for (User salesAssistant : [SELECT Id, Sales_Assistant_Code__c FROM User WHERE Sales_Assistant_Code__c IN :salesAssistantsCodesSet]) {
                code_salesAssistant.put(salesAssistant.Sales_Assistant_Code__c, salesAssistant.Id);
            }
            
            // Obter o respetivo ID do Sales Assistant associado ao Canvasser.
            if (!code_salesAssistant.isEmpty()) {
                for (Opportunity newOpp : newOppsList) {                
                    String code;
                    if(newOpp.Canvasser__c != null && canvasserSalesAssistantCodes.get(newOpp.Canvasser__c) != null ){
                        code = canvasserSalesAssistantCodes.get(newOpp.Canvasser__c).Sales_Assistant_IH__c;                        
                    }                    
                    if (code != null)
                        newOpp.Sales_Assistant__c = code_salesAssistant.get(Decimal.valueOf(code)); 
                }
            }            
        }        
    }
    
    private static void checkOpportunityLineItems(List<Opportunity> opportunityList) {
        Map<Id, Opportunity> opportunityById = new Map<Id, Opportunity>(opportunityList);
        
        List<AggregateResult> oppsToSyncLineItems = [
            SELECT OpportunityId
            FROM OpportunityLineItem
            WHERE 
            RecID__c = null AND
            OpportunityId IN :opportunityById.keySet() AND 
            Product2.Transportation__c = false AND
            (Product2.ProductCode != 'Litoral' AND Product2.ProductCode != 'Interior' AND Product2.ProductCode != 'Algarve')
            GROUP BY OpportunityId
        ];
        
        for(AggregateResult aggregateResult : oppsToSyncLineItems) {
            Id oppId = (Id) aggregateResult.get('OpportunityId');
            Opportunity opp = opportunityById.get(oppId);
            opp.addError(
                'Não é possivel mudar o status para "Geração de Contrato" sem ter todas os oppLineItem syncronizados com o Insphire.' +
                'Clique no botão "Sincronizar OppLineItems"'
            );
        }
    }
    
    public static void updateExternalNotesQuote(List<Opportunity> newOpps, Map<Id, Opportunity> oldOppsMap) {        
        List<SBQQ__Quote__c> quotesToUpdate = new List<SBQQ__Quote__c>();
        List<ID> QuoteIDs = new List<ID>();
        List<SBQQ__Quote__c> qList = new List<SBQQ__Quote__c>();
        
        for(Opportunity oppQuote: newOpps){
            if(oppQuote.SBQQ__PrimaryQuote__c != null){
                QuoteIDs.add(oppQuote.SBQQ__PrimaryQuote__c);
            }            
        }        
        if(!QuoteIDs.isEmpty()){
            qList = [
                SELECT Id, SBQQ__Notes__c
                FROM SBQQ__Quote__c
                WHERE Id = :QuoteIDs
            ];
        }        
        for (Opportunity newOpp : newOpps) {
            Opportunity oldOpp = oldOppsMap.get(newOpp.id);
            if (newOpp.External_notes__c != oldOpp.External_notes__c) {
                for(SBQQ__Quote__c QT :qList){    
                    if( (QT.ID == newOpp.SBQQ__PrimaryQuote__c) && (newOpp.External_notes__c != QT.SBQQ__Notes__c) ){
                        QT.SBQQ__Notes__c = newOpp.External_notes__c;
                        quotesToUpdate.add(QT);   
                    }
                }      
            }
        }       
        if(!quotesToUpdate.isEmpty()){
            update quotesToUpdate;  
        }
    }    
}